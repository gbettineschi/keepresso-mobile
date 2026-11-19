#!/usr/bin/env python3
"""Import a project identity only on a fresh signing-only GitHub runner."""
import argparse
import base64
import binascii
import importlib.util
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


candidate = load('sign_candidate', Path(__file__).with_name('sign-candidate.py'))
policy = load('release_policy', Path(__file__).resolve().parents[2] / 'scripts/release-policy.py')


def execute(command):
    result = subprocess.run(command, text=True, capture_output=True)
    if result.returncode:
        # Never include argv or tool output: either can contain a secret.
        raise ValueError(f'Signing tool {Path(command[0]).name} failed (exit {result.returncode})')
    return result.stdout


def directory(environment):
    parent = Path(environment.get('RUNNER_TEMP', ''))
    if not parent.is_absolute() or not parent.is_dir() or parent.is_symlink():
        raise ValueError('A private runner temporary directory is required')
    return parent / 'keepresso-project-signing'


def cleanup(environment, *, runner=execute):
    root = directory(environment)
    if not root.exists(): return
    if root.is_symlink() or not root.is_dir(): raise ValueError('Unsafe signing cleanup directory')
    keychain = root / 'signing.keychain-db'
    try:
        if keychain.exists(): runner(['/usr/bin/security', 'delete-keychain', str(keychain)])
    finally:
        shutil.rmtree(root)


def sign(input_zip, output_zip, source_sha, environment, *, runner=execute, packager=candidate.sign_candidate):
    result = policy.from_environment(environment)
    if not result['sign_mac'] or source_sha != result['source_sha']:
        raise ValueError('This exact run is not approved for project signing')
    encoded = environment.get('MACOS_SIGNING_PKCS12_BASE64', '')
    password = environment.get('MACOS_SIGNING_PKCS12_PASSWORD', '')
    fingerprint = environment.get('MACOS_SIGNING_CERTIFICATE_SHA1', '')
    if not 8 <= len(password) <= 1024 or re.fullmatch(r'[0-9a-fA-F]{40}', fingerprint) is None or not encoded or len(encoded) > 48000:
        raise ValueError('Complete project signing configuration is required; no replacement key will be generated')
    try: p12 = base64.b64decode(encoded, validate=True)
    except (ValueError, binascii.Error) as error: raise ValueError('Invalid encrypted signing identity') from error
    if not p12: raise ValueError('Empty encrypted signing identity')
    root = directory(environment)
    root.mkdir(mode=0o700)  # Refuse leftovers instead of overwriting any key.
    keychain = root / 'signing.keychain-db'
    original_search_list = runner(['/usr/bin/security', 'list-keychains', '-d', 'user'])
    try:
        identity = root / 'identity.p12'
        with identity.open('xb') as file:
            identity.chmod(0o600); file.write(p12)
        temporary_password = secrets.token_urlsafe(32)
        runner(['/usr/bin/security','create-keychain','-p',temporary_password,str(keychain)])
        keychain.chmod(0o600)
        runner(['/usr/bin/security','unlock-keychain','-p',temporary_password,str(keychain)])
        runner(['/usr/bin/security','import',str(identity),'-k',str(keychain),'-P',password,'-T','/usr/bin/codesign'])
        return packager(input_zip, output_zip, fingerprint, keychain, source_sha)
    finally:
        cleanup(environment, runner=runner)
        if runner(['/usr/bin/security', 'list-keychains', '-d', 'user']) != original_search_list:
            raise ValueError('Temporary signing keychain was not removed cleanly')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input_zip', nargs='?'); parser.add_argument('output_zip', nargs='?')
    parser.add_argument('--source-sha'); parser.add_argument('--cleanup-only', action='store_true')
    args = parser.parse_args()
    try:
        if args.cleanup_only: cleanup(os.environ); return
        if not args.input_zip or not args.output_zip or not args.source_sha: parser.error('Input, output and source SHA are required')
        print(json.dumps(sign(args.input_zip, args.output_zip, args.source_sha, os.environ), indent=2))
    except (ValueError, OSError):
        parser.exit(2, 'Project signing failed; no fallback identity or installer was published.\n')


if __name__ == '__main__': main()

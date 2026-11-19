#!/usr/bin/env python3
"""Opt-in real signature fixture: temporary keys only, no trust or privacy grants."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import secrets
import shutil
import subprocess
import tempfile
import zipfile


def run(args, *, env=None, check=True):
    result = subprocess.run(args, env=env, capture_output=True, text=True)
    if check and result.returncode:
        raise AssertionError(f'{Path(args[0]).name} failed (exit {result.returncode})')
    return result


def requirement(app):
    result = run(['codesign', '--display', '-r-', str(app)])
    return next(line.removeprefix('designated => ') for line in (result.stdout + result.stderr).splitlines()
                if line.startswith('designated => '))


def identity(app, *, check=True):
    result = run([str(app / 'Contents/MacOS/KeepressoMac'), '--read-authorization-identity'], check=check)
    if not check:
        return result
    return json.loads(result.stdout)['identity']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--allow-temporary-keychain-probe', action='store_true')
    parser.add_argument('--app', required=True, type=Path)
    args = parser.parse_args()
    if not args.allow_temporary_keychain_probe:
        parser.error('Explicit temporary-keychain probe consent is required')
    app = args.app.resolve()
    if app.name != 'KeepressoMobile.app' or '.build' not in app.parts:
        parser.error('Use only a hidden .build fixture, never an installed app')
    run(['codesign', '--verify', '--deep', '--strict', str(app)])
    assert not identity(app).startswith('certificate-v1|'), 'Fixture must start ad-hoc'
    before = run(['security', 'list-keychains', '-d', 'user']).stdout
    record = {}
    with tempfile.TemporaryDirectory(prefix='keepresso-private-signature-fixture-') as temporary:
        root = Path(temporary)
        root.chmod(0o700)
        keychain = root / 'fixture.keychain-db'
        password = secrets.token_urlsafe(32)
        try:
            run(['security', 'create-keychain', '-p', password, str(keychain)])
            run(['security', 'unlock-keychain', '-p', password, str(keychain)])
            certs = []
            for number in (1, 2):
                directory = root / f'cert{number}'
                directory.mkdir(mode=0o700)
                config = directory / 'cert.cnf'
                config.write_text('[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n'
                                  '[dn]\nCN=Keepresso Ephemeral Fixture\n[ext]\nbasicConstraints=critical,CA:FALSE\n'
                                  'keyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n')
                pem, key, p12 = (directory / name for name in ('cert.pem', 'key.pem', 'fixture.p12'))
                run(['openssl', 'req', '-new', '-newkey', 'rsa:2048', '-x509', '-sha256', '-nodes', '-days', '1',
                     '-config', str(config), '-keyout', str(key), '-out', str(pem)])
                key.chmod(0o600)
                environment = os.environ.copy()
                environment['KEEPRESSO_FIXTURE_PASSWORD'] = password
                run(['openssl', 'pkcs12', '-export', '-inkey', str(key), '-in', str(pem), '-out', str(p12),
                     '-passout', 'env:KEEPRESSO_FIXTURE_PASSWORD'], env=environment)
                run(['security', 'import', str(p12), '-k', str(keychain), '-P', password, '-T', '/usr/bin/codesign'])
                der = subprocess.run(['openssl', 'x509', '-in', str(pem), '-outform', 'DER'], check=True, capture_output=True).stdout
                certs.append((hashlib.sha1(der).hexdigest(), hashlib.sha256(der).hexdigest()))
            apps = []
            script = Path(__file__).with_name('sign-app.sh')
            for index in range(3):
                destination = root / str(index) / 'KeepressoMobile.app'
                shutil.copytree(app, destination)
                info = destination / 'Contents/Info.plist'
                data = plistlib.loads(info.read_bytes())
                data['CFBundleShortVersionString'] = f'0.0.{index+1}'
                data['CFBundleVersion'] = str(index+1)
                info.write_bytes(plistlib.dumps(data))
                environment = os.environ.copy()
                environment.update(KEEPRESSO_SIGNING_PROFILE='project', KEEPRESSO_REQUIRE_STABLE_SIGNING='1',
                                   KEEPRESSO_CODESIGN_IDENTITY=certs[index // 2][0], KEEPRESSO_CODESIGN_KEYCHAIN=str(keychain))
                run(['bash', str(script), str(destination)], env=environment)
                apps.append(destination)
            a, b, c = apps
            assert requirement(a) == requirement(b)
            assert (a / 'Contents/MacOS/KeepressoMac').read_bytes() != (b / 'Contents/MacOS/KeepressoMac').read_bytes()
            for candidate in (a, b):
                run(['codesign', '--verify', '--deep', '--strict', '--test-requirement', '=' + requirement(a), str(candidate)])
            expected = 'certificate-v1|local.keespresso.companion|' + certs[0][1]
            assert identity(a) == identity(b) == expected, 'Actual running-code identity must survive an update'
            assert identity(c) != expected, 'Same-name different certificate must not inherit consent'
            assert run(['codesign', '--verify', '--strict', '--test-requirement', '=' + requirement(a), str(c)], check=False).returncode != 0
            # Exercise the exact signing-only archive API with the real fixture key.
            source = root / 'input.zip'
            with zipfile.ZipFile(source, 'w', zipfile.ZIP_DEFLATED) as archive:
                for file in app.rglob('*'):
                    if file.is_file():
                        archive.write(file, 'KeepressoMobile.app/' + file.relative_to(app).as_posix())
            spec = importlib.util.spec_from_file_location('candidate', Path(__file__).with_name('sign-candidate.py'))
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            output = root / 'signed.zip'
            receipt = module.sign_candidate(source, output, certs[0][0], keychain, 'a' * 40)
            assert receipt['sha256'] == hashlib.sha256(output.read_bytes()).hexdigest()
            with zipfile.ZipFile(output) as archive:
                assert all(name.startswith('KeepressoMobile.app/') for name in archive.namelist())
                archive.extractall(root / 'checked')
            run(['codesign', '--verify', '--deep', '--strict', str(root / 'checked/KeepressoMobile.app')])
            # Exercise the CI import/cleanup wrapper with fixture secrets only.
            spec = importlib.util.spec_from_file_location('ci_signing', Path(__file__).with_name('ci-project-signing.py'))
            ci = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(ci)
            runner_temp = root / 'runner-temp'
            runner_temp.mkdir(mode=0o700)
            event = root / 'event.json'
            event.write_text(json.dumps({'inputs': {'tag': 'v0.0.3', 'mode': 'mac-trial', 'expected_sha': 'a' * 40}}))
            import base64
            environment = {'RUNNER_TEMP': str(runner_temp), 'GITHUB_REPOSITORY': 'gbettineschi/keepresso-mobile',
                           'GITHUB_EVENT_NAME': 'workflow_dispatch', 'GITHUB_REF': 'refs/heads/fixture',
                           'GITHUB_SHA': 'a' * 40, 'GITHUB_EVENT_PATH': str(event),
                           'MACOS_SIGNING_PKCS12_BASE64': base64.b64encode((root / 'cert1/fixture.p12').read_bytes()).decode(),
                           'MACOS_SIGNING_PKCS12_PASSWORD': password, 'MACOS_SIGNING_CERTIFICATE_SHA1': certs[0][0]}
            ci.sign(source, root / 'ci-signed.zip', 'a' * 40, environment)
            assert not (runner_temp / 'keepresso-project-signing').exists()
            info = a / 'Contents/Info.plist'
            info.write_bytes(info.read_bytes() + b'\n')
            assert run(['codesign', '--verify', '--deep', '--strict', str(a)], check=False).returncode != 0
            assert identity(a, check=False).returncode != 0, 'Tampered resources must invalidate reusable identity'
            record = dict(sameCertificateAcrossUpdates=True, changedSignedBytes=True, wrongCertificateRejected=True,
                          tamperingRejected=True, realArchiveSignerPassed=True, actualPrivacyIdentityPassed=True, realCIWrapperPassed=True,
                          tccGranted=False, trustChanged=False)
        finally:
            if keychain.exists():
                run(['security', 'delete-keychain', str(keychain)])
            assert run(['security', 'list-keychains', '-d', 'user']).stdout == before, 'Temporary keychain search list not restored'
    record['temporaryMaterialRemoved'] = True
    print(json.dumps(record, indent=2))


if __name__ == '__main__':
    main()

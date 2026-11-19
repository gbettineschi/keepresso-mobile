#!/usr/bin/env python3
"""Fail-closed release routing, shared by the keyless gate and private signer."""
import importlib.util
import json
import os
from pathlib import Path
import re

spec = importlib.util.spec_from_file_location('release_version', Path(__file__).with_name('release-version.py'))
version = importlib.util.module_from_spec(spec)
spec.loader.exec_module(version)


def plan(repository, event, ref, sha, inputs):
    if repository != 'gbettineschi/keepresso-mobile' or re.fullmatch(r'[0-9a-f]{40}', sha) is None:
        raise ValueError('Only the exact project repository and commit may use this release workflow')
    if event == 'push' and ref.startswith('refs/tags/'):
        tag = ref.removeprefix('refs/tags/')
        sign_mac, build_android, publish = True, True, True
    elif event == 'workflow_dispatch' and ref.startswith('refs/heads/'):
        mode, tag = inputs.get('mode', 'verify'), inputs.get('tag', '')
        if mode not in ('verify', 'mac-trial'):
            raise ValueError('Unknown release mode')
        sign_mac, build_android, publish = mode == 'mac-trial', mode == 'verify', False
        if sign_mac and inputs.get('expected_sha') != sha:
            raise ValueError('The Mac trial requires the exact reviewed source commit')
    else:
        raise ValueError('This event or ref cannot enter the release path')
    version.release_version(tag)
    return dict(sign_mac=sign_mac, build_android=build_android, publish=publish, tag=tag, source_sha=sha)


def from_environment(environment):
    try:
        event = json.loads(Path(environment['GITHUB_EVENT_PATH']).read_text())
        return plan(environment['GITHUB_REPOSITORY'], environment['GITHUB_EVENT_NAME'], environment['GITHUB_REF'],
                    environment['GITHUB_SHA'], event.get('inputs', {}))
    except (KeyError, TypeError, OSError, json.JSONDecodeError) as error:
        raise ValueError('Missing or invalid release event context') from error


if __name__ == '__main__':
    try:
        result = from_environment(os.environ)
    except ValueError as error:
        raise SystemExit(str(error))
    for key, value in result.items():
        print(f'{key}={str(value).lower() if isinstance(value, bool) else value}')

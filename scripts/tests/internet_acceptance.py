#!/usr/bin/env python3
"""Production iroh/session interoperability with synthetic authorization. Emulator only."""
import argparse
import base64
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = 'io.github.gbettineschi.keepressomobile'


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--sdk', type=Path, required=True)
    p.add_argument('--serial', default='emulator-5554')
    p.add_argument('--mode', choices=['auto', 'relay', 'both'], default='both')
    p.add_argument('--case', help='One named instrumentation method for diagnosis')
    a = p.parse_args()
    if not re.fullmatch(r'emulator-[0-9]+', a.serial):
        p.error('This runner never installs on physical devices')
    if a.case and not re.fullmatch(r'[A-Za-z]+', a.case):
        p.error('Invalid method')
    adb = [str(a.sdk / 'platform-tools/adb'), '-s', a.serial]

    def call(*args, timeout=180):
        return subprocess.check_output(adb + list(args), text=True, stderr=subprocess.STDOUT, timeout=timeout)

    if call('shell', 'getprop', 'ro.hardware').strip() != 'ranchu' or not call('emu', 'avd', 'name').splitlines()[0].startswith('Keepresso_'):
        raise RuntimeError('Use the dedicated Keepresso emulator')
    output = ROOT / '.superpowers/sdd/2026-10-30-iroh-firebase/production-internet'
    output.mkdir(parents=True, exist_ok=True)
    binary = ROOT / 'macos/.build/arm64-apple-macosx/release/InternetFixture'
    if not binary.is_file():
        raise RuntimeError('Build the native InternetFixture product first')
    for apk in ('debug/app-debug.apk', 'androidTest/debug/app-debug-androidTest.apk'):
        call('install', '-r', str(ROOT / 'android/app/build/outputs/apk' / apk))
    summary = {'syntheticOnly': True, 'runs': []}
    for mode in (['auto', 'relay'] if a.mode == 'both' else [a.mode]):
        directory = output / mode
        directory.mkdir(exist_ok=True)
        state = directory / 'state'
        state.mkdir(mode=0o700, exist_ok=True)
        ready = directory / 'ready.json'
        with socket.socket() as s:
            s.bind(('127.0.0.1', 0))
            port = s.getsockname()[1]
        process = None
        log = None

        def stop():
            nonlocal process, log
            if process and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
            if log:
                log.close()
            process = log = None

        def start(label):
            nonlocal process, log
            ready.unlink(missing_ok=True)
            log = (directory / (label + '-server.log')).open('w')
            process = subprocess.Popen([str(binary), mode, str(state), str(port), str(ready)], stdout=log, stderr=log)
            deadline = time.monotonic() + 35
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError('Fixture exited; inspect its local log')
                if ready.exists():
                    value = json.loads(ready.read_text())
                    assert value['synthetic'] is True and value['bootstrapPort'] == port
                    assert len(base64.b64decode(value['endpointId'], validate=True)) == 32
                    return value['endpointId']
                time.sleep(.1)
            raise RuntimeError('Fixture did not bind within its deadline')

        def instrument(label, method=None, restart=False):
            clazz = PACKAGE + '.ProductionInternetTest' + ('#' + method if method else '')
            try:
                result = call('shell', 'am', 'instrument', '-w', '-r', '-e', 'class', clazz,
                              '-e', 'bootstrapPort', str(port), '-e', 'mode', mode,
                              '-e', 'restart', str(restart).lower(),
                              PACKAGE + '.test/androidx.test.runner.AndroidJUnitRunner', timeout=90 if a.case else 300)
            except subprocess.TimeoutExpired as error:
                partial = error.stdout or b''
                if isinstance(partial, bytes):
                    partial = partial.decode('utf-8', errors='replace')
                (directory / (label + '.log')).write_text(partial)
                call('shell', 'am', 'force-stop', PACKAGE)
                raise
            (directory / (label + '.log')).write_text(result)
            match = re.search(r'OK \((\d+) tests?\)', result)
            if not match:
                print(result[-2500:], flush=True)
                raise RuntimeError(f'{mode}/{label} failed')
            record = {'mode': mode, 'phase': label, 'tests': int(match[1]),
                      'metrics': re.findall(r'PRODUCTION(?:_PATH)? [^\n]+', result)}
            summary['runs'].append(record)
            print(json.dumps(record), flush=True)

        try:
            call('shell', 'am', 'force-stop', PACKAGE)
            call('shell', 'pm', 'clear', PACKAGE)
            identity = start('initial')
            instrument('initial', a.case)
            if not a.case:
                call('shell', 'am', 'force-stop', PACKAGE)
                stop()
                assert start('restarted') == identity, 'Mac endpoint changed across restart'
                instrument('restarted', 'identityEnrollmentAndRestartLookup', True)
        finally:
            stop()
    (output / 'results.json').write_text(json.dumps(summary, indent=2) + '\n')
    print('Production protocol cases passed:', sum(r['tests'] for r in summary['runs']), flush=True)


if __name__ == '__main__':
    main()

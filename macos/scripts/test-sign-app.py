#!/usr/bin/env python3
"""Packaging contract tests. Fake signer; never read or mutate real Keychains."""
import os
import plistlib
import shutil
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT=Path(__file__).with_name('sign-app.sh')
IDENTITY='1234567890ABCDEF1234567890ABCDEF12345678'

class SigningTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='keepresso-sign-test-')
        self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);(self.root/'Companion.app').mkdir()
        self.log=self.root/'calls'
        fake=self.root/'codesign'
        fake.write_text('''#!/usr/bin/env python3
import json,os,sys
with open(os.environ['SIGN_TEST_LOG'],'a') as f:f.write(json.dumps(sys.argv[1:])+'\\n')
if '--sign' in sys.argv and os.environ.get('SIGN_TEST_FAIL'):sys.exit(9)
if '--test-requirement' in sys.argv and os.environ.get('SIGN_TEST_UNSUPPORTED_TEAM') and 'anchor apple generic' in sys.argv[sys.argv.index('--test-requirement')+1]:sys.exit(10)
if '--display' in sys.argv:
 if os.environ.get('SIGN_TEST_PATH'):print('Executable='+os.environ['SIGN_TEST_PATH'],file=sys.stderr)
 requirement='cdhash H"abcd"' if os.environ.get('SIGN_TEST_HASH') else 'identifier "local.keespresso.companion"' if os.environ.get('SIGN_TEST_BROAD_DR') else 'identifier "local.keespresso.companion" and anchor H"1234"'
 print('designated => '+requirement,file=sys.stderr)
''')
        fake.chmod(0o700)
        self.env={k:v for k,v in os.environ.items() if not k.startswith('KEEPRESSO_CODESIGN_') and k!='KEEPRESSO_REQUIRE_STABLE_SIGNING'}
        self.env.update(PATH=str(self.root)+os.pathsep+self.env['PATH'],SIGN_TEST_LOG=str(self.log))
    def run_sign(self,**env):
        return subprocess.run(['bash',str(SCRIPT),str(self.root/'Companion.app')],env=self.env|env,text=True,capture_output=True)
    def calls(self):
        import json
        return [json.loads(x) for x in self.log.read_text().splitlines()] if self.log.exists() else []
    def test_stable_mode_refuses_missing_identity_before_signing(self):
        result=self.run_sign(KEEPRESSO_REQUIRE_STABLE_SIGNING='1')
        self.assertEqual(result.returncode,2);self.assertEqual(self.calls(),[])
        self.assertIn('certificate',result.stderr.lower())
    def test_explicit_certificate_is_used_and_verified_against_expected_app(self):
        result=self.run_sign(KEEPRESSO_CODESIGN_IDENTITY=IDENTITY,KEEPRESSO_REQUIRE_STABLE_SIGNING='1')
        self.assertEqual(result.returncode,0,result.stderr)
        calls=self.calls();self.assertIn(IDENTITY,calls[0])
        verification=next(c for c in calls if '--test-requirement' in c)
        rule=verification[verification.index('--test-requirement')+1]
        self.assertIn(IDENTITY,rule);self.assertIn('local.keespresso.companion',rule)
    def test_invalid_explicit_identity_never_falls_back_to_ad_hoc(self):
        result=self.run_sign(KEEPRESSO_CODESIGN_IDENTITY='mistyped identity')
        self.assertEqual(result.returncode,2);self.assertEqual(self.calls(),[])
    def test_signing_failure_is_not_reported_as_success(self):
        result=self.run_sign(KEEPRESSO_CODESIGN_IDENTITY=IDENTITY,SIGN_TEST_FAIL='1')
        self.assertEqual(result.returncode,9);self.assertEqual(len(self.calls()),1)
    def test_certificate_path_rejects_build_hash_only_designated_requirement(self):
        result=self.run_sign(KEEPRESSO_CODESIGN_IDENTITY=IDENTITY,SIGN_TEST_HASH='1')
        self.assertEqual(result.returncode,2)
    def test_ad_hoc_development_build_warns_about_repeated_keychain_approval(self):
        result=self.run_sign()
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('-',self.calls()[0]);self.assertIn('Keychain',result.stderr)
    def test_self_signed_certificate_cannot_be_claimed_to_fix_partition_identity(self):
        result=self.run_sign(KEEPRESSO_CODESIGN_IDENTITY=IDENTITY,SIGN_TEST_UNSUPPORTED_TEAM='1')
        self.assertEqual(result.returncode,10)
    def test_path_text_cannot_make_a_broad_designated_requirement_look_certificate_bound(self):
        result=self.run_sign(KEEPRESSO_CODESIGN_IDENTITY=IDENTITY,SIGN_TEST_BROAD_DR='1',SIGN_TEST_PATH='/tmp/anchor-certificate/Companion.app')
        self.assertEqual(result.returncode,2)
    def test_valid_certificate_requirement_is_not_confused_by_a_cdhash_directory_name(self):
        result=self.run_sign(KEEPRESSO_CODESIGN_IDENTITY=IDENTITY,SIGN_TEST_PATH='/tmp/cdhash-check/Companion.app')
        self.assertEqual(result.returncode,0,result.stderr)
    @unittest.skipUnless(Path('/usr/libexec/PlistBuddy').exists(),'requires Mac packaging tools')
    def test_release_archive_preserves_the_explicit_signing_identity(self):
        repo=self.root/'repo';scripts=repo/'macos/scripts';scripts.mkdir(parents=True)
        (repo/'scripts').mkdir();(repo/'macos/ThirdParty/KeepressoCore').mkdir(parents=True)
        for name in ['LICENSE','THIRD_PARTY_NOTICES.md','macos/ThirdParty/KeepressoCore/LICENSE']:
            (repo/name).write_text('Fixture licence')
        (repo/'scripts/verify-upstream.py').write_text('')
        source=SCRIPT.parents[2]
        shutil.copyfile(source/'scripts/release-version.py',repo/'scripts/release-version.py')
        shutil.copyfile(SCRIPT,scripts/'sign-app.sh')
        shutil.copyfile(SCRIPT.with_name('package-release.sh'),scripts/'package-release.sh')
        (scripts/'build-app.sh').write_text('''#!/bin/bash
set -euo pipefail
mkdir -p "$KEEPRESSO_APP_DESTINATION/Contents/MacOS" "$KEEPRESSO_APP_DESTINATION/Contents/Resources"
python3 - <<'PY'
import os,plistlib
from pathlib import Path
app=Path(os.environ['KEEPRESSO_APP_DESTINATION'])
(app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString':'0.0.0','CFBundleVersion':'1'}))
p=app/'Contents/MacOS/KeepressoMac';p.write_text('#!/bin/sh\\nexit 0\\n');p.chmod(0o700)
PY
bash "$(dirname "$0")/sign-app.sh" "$KEEPRESSO_APP_DESTINATION"
''')
        for name,body in [('uname','echo arm64'),('lipo','exit 0'),('ditto','touch "${@: -1}"')]:
            p=self.root/name;p.write_text('#!/bin/bash\n'+body+'\n');p.chmod(0o700)
        result=subprocess.run(['bash',str(scripts/'package-release.sh'),'v0.4.7'],cwd=repo,
                              env=self.env|{'KEEPRESSO_CODESIGN_IDENTITY':IDENTITY,'KEEPRESSO_REQUIRE_STABLE_SIGNING':'1'},text=True,capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr)
        signatures=[call for call in self.calls() if '--sign' in call]
        self.assertEqual(len(signatures),2)
        self.assertTrue(all(call[call.index('--sign')+1]==IDENTITY for call in signatures))
        info=plistlib.loads((repo/'macos/artifacts/KeepressoMobile.app/Contents/Info.plist').read_bytes())
        self.assertEqual(info['CFBundleShortVersionString'],'0.4.7');self.assertEqual(info['CFBundleVersion'],'4007')

if __name__=='__main__':unittest.main()

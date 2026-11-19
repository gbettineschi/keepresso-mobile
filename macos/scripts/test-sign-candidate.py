#!/usr/bin/env python3
"""Validate the signing boundary using controlled archives and a fake external signer."""
import importlib.util
import os
from pathlib import Path
import plistlib
import stat
import tempfile
import unittest
from unittest.mock import patch
import struct
import zipfile

PATH = Path(__file__).with_name('sign-candidate.py')
IDENTITY = '1234567890ABCDEF1234567890ABCDEF12345678'
SOURCE = 'a' * 40
ROOT = 'KeepressoMobile.app/'


class CandidateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location('candidate', PATH)
        cls.code = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.code)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='keepresso-candidate-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.input = self.root / 'input.zip'
        self.output = self.root / 'signed.zip'
        self.keychain = self.root / 'fixture.keychain-db'
        self.keychain.touch()
        self.requirement = 'identifier "local.keespresso.companion" and certificate leaf = H"' + IDENTITY.lower() + '"'
        self.fail_signer = False
        self.output_race = False

    def runner(self, command, *, env=None):
        # A candidate invocation, build, open, Swift or arbitrary shell command is a test failure.
        if command[0] == 'codesign':
            if self.fail_signer:
                raise RuntimeError('fixture invalid signature')
            if '--display' in command:
                if self.output_race:self.output.write_bytes(b'concurrent artifact')
                return 'Executable=/fixture/Companion.app\ndesignated => ' + self.requirement + '\n'
            self.assertIn('--verify', command)
            return ''
        if command[0] == 'bash':
            self.assertEqual(Path(command[1]).name, 'sign-app.sh')
            self.assertEqual(env['KEEPRESSO_SIGNING_PROFILE'], 'project')
            self.assertEqual(env['KEEPRESSO_CODESIGN_IDENTITY'], IDENTITY)
            self.assertEqual(env['KEEPRESSO_CODESIGN_KEYCHAIN'], str(self.keychain))
            return ''
        raise AssertionError('Candidate execution or unexpected signing command: ' + command[0])

    def archive(self, extra=(), identifier='local.keespresso.companion', main=b'\xcf\xfa\xed\xfe' + b'fixture', duplicate=False):
        info = plistlib.dumps({'CFBundleIdentifier': identifier, 'CFBundleExecutable': 'KeepressoMac',
                              'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '0.6.13', 'CFBundleVersion': '6013'})
        members = [(ROOT+'Contents/Info.plist', info, 0o644),
                   (ROOT+'Contents/MacOS/KeepressoMac', main, 0o755),
                   (ROOT+'Contents/Resources/LICENSE.txt', b'Fixture licence', 0o644)] + list(extra)
        if duplicate:
            members.append((ROOT+'Contents/Info.plist', info, 0o644))
        with zipfile.ZipFile(self.input, 'w', zipfile.ZIP_DEFLATED) as z:
            for name, data, mode in members:
                item=zipfile.ZipInfo(name);item.create_system=3
                item.external_attr=((stat.S_IFREG|mode) if mode < 0o10000 else mode) << 16
                z.writestr(item,data)

    def sign(self, **changes):
        return self.code.sign_candidate(self.input,self.output,changes.get('certificate_sha1',IDENTITY),
                                        self.keychain,changes.get('source_sha',SOURCE),runner=self.runner)

    def test_valid_app_is_packaged_without_executing_candidate_or_including_siblings(self):
        self.archive()
        (self.root/'private.p12').write_bytes(b'fixture must never enter package')
        receipt=self.sign()
        self.assertEqual(receipt['sourceCommit'],SOURCE)
        self.assertEqual(receipt['certificateSha1'],IDENTITY.lower())
        with zipfile.ZipFile(self.output) as z:
            self.assertEqual(set(z.namelist()),{ROOT+'Contents/Info.plist',ROOT+'Contents/MacOS/KeepressoMac',ROOT+'Contents/Resources/LICENSE.txt'})
            self.assertTrue(z.getinfo(ROOT+'Contents/MacOS/KeepressoMac').external_attr >> 16 & 0o111)

    def test_path_escape_is_rejected_without_signing(self):
        for path in ['../escape','/absolute','KeepressoMobile.app/../escape','KeepressoMobile.app//Contents/evil','KeepressoMobile.app\\escape']:
            with self.subTest(path=path):
                self.archive([(path,b'escape',0o644)])
                with self.assertRaises(ValueError):self.sign()
                self.assertFalse(self.output.exists())

    def test_symlink_duplicate_and_case_collision_are_rejected(self):
        for extra, duplicate in [([(ROOT+'Contents/link',b'/tmp/elsewhere',stat.S_IFLNK|0o777)],False),([],True),([(ROOT+'Contents/info.plist',b'collision',0o644)],False)]:
            with self.subTest(extra=extra,duplicate=duplicate):
                self.archive(extra,duplicate=duplicate)
                with self.assertRaises(ValueError):self.sign()
                self.assertFalse(self.output.exists())

    def test_other_bundle_identifier_is_rejected(self):
        self.archive(identifier='different.app')
        with self.assertRaises(ValueError):self.sign()
        self.assertFalse(self.output.exists())

    def test_nested_executable_and_private_material_are_rejected(self):
        for name,data in [(ROOT+'Contents/Resources/extra.dylib',b'\xcf\xfa\xed\xfeother'),
                          (ROOT+'Contents/MacOS/other',b'#!/bin/sh\nexit 0'),
                          (ROOT+'Contents/Resources/key.p12',b'fixture key')]:
            with self.subTest(name=name):
                self.archive([(name,data,0o755)])
                with self.assertRaises(ValueError):self.sign()
                self.assertFalse(self.output.exists())

    def test_script_main_is_not_executed_as_a_self_check(self):
        marker=self.root/'must-not-exist'
        self.archive(main=f'#!/bin/sh\ntouch "{marker}"\n'.encode())
        with self.assertRaises(ValueError):self.sign()
        self.assertFalse(marker.exists());self.assertFalse(self.output.exists())

    def test_failed_signature_never_produces_output(self):
        self.archive();self.fail_signer=True
        with self.assertRaises(ValueError):self.sign()
        self.assertFalse(self.output.exists())

    def test_wrong_or_broad_project_requirement_never_produces_output(self):
        self.archive()
        for requirement in ['identifier "local.keespresso.companion"',self.requirement.replace(' and ',' or '),self.requirement.replace('12345678','87654321')]:
            self.requirement=requirement
            with self.subTest(requirement=requirement):
                with self.assertRaises(ValueError):self.sign()
                self.assertFalse(self.output.exists())

    def test_invalid_certificate_and_source_inputs_are_rejected(self):
        self.archive()
        for kwargs in [{'certificate_sha1':'project-name'}, {'source_sha':'$(unsafe)'}, {'source_sha':'a'*39}]:
            with self.subTest(kwargs=kwargs):
                with self.assertRaises(ValueError):self.sign(**kwargs)
                self.assertFalse(self.output.exists())

    def test_wrong_incoming_signing_identifier_never_reaches_private_signer(self):
        self.archive()
        calls=[]
        def checking(command, **kwargs):
            calls.append(command)
            if '--verify' in command and '--test-requirement' in command and 'certificate leaf' not in ' '.join(command):
                raise ValueError('fixture incoming signing identifier does not match')
            return self.runner(command, **kwargs)
        with self.assertRaises(ValueError):
            self.code.sign_candidate(self.input,self.output,IDENTITY,self.keychain,SOURCE,runner=checking)
        self.assertFalse(any(command[0]=='bash' for command in calls))

    def test_oversized_directory_or_unsupported_zip_is_refused_before_zipfile(self):
        self.archive()
        original=self.input.read_bytes()
        marker=original.rfind(b'PK\x05\x06')
        # The source file is otherwise a valid small package. Only its declared
        # directory metadata is malicious; ZipFile must not enumerate it first.
        cases=[(10,struct.pack('<H',4097)), (12,struct.pack('<I',2*1024*1024)),
               (4,struct.pack('<H',1)), (16,struct.pack('<I',0xffffffff))]
        for offset,value in cases:
            mutated=bytearray(original);mutated[marker+offset:marker+offset+len(value)]=value
            self.input.write_bytes(mutated)
            with self.subTest(offset=offset), patch.object(self.code.zipfile,'ZipFile',side_effect=AssertionError('parsed before bounds')):
                with self.assertRaises(ValueError): self.sign()
        self.assertFalse(self.output.exists())

    def test_concurrently_created_output_is_never_overwritten(self):
        self.archive();self.output_race=True
        with self.assertRaises(ValueError):self.sign()
        self.assertEqual(self.output.read_bytes(),b'concurrent artifact')

    def test_existing_output_and_oversized_input_are_rejected(self):
        self.archive();self.output.write_bytes(b'original')
        with self.assertRaises(ValueError):self.sign()
        self.assertEqual(self.output.read_bytes(),b'original')
        self.output.unlink()
        with self.input.open('r+b') as f:f.truncate(256*1024*1024+1)
        with self.assertRaises(ValueError):self.sign()
        self.assertFalse(self.output.exists())

if __name__=='__main__':unittest.main()

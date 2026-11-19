import base64
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('ci_signing', Path(__file__).with_name('ci-project-signing.py'))
ci = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci)


class CISigningTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name); self.calls = []; self.packed = False; self.fail_import = False
        self.environment = {'RUNNER_TEMP':str(self.root),'GITHUB_REPOSITORY':'gbettineschi/keepresso-mobile',
            'GITHUB_EVENT_NAME':'workflow_dispatch','GITHUB_REF':'refs/heads/fix/signing','GITHUB_SHA':'a'*40,
            'MACOS_SIGNING_PKCS12_BASE64':base64.b64encode(b'opaque fixture PKCS12').decode(),
            'MACOS_SIGNING_PKCS12_PASSWORD':'long fixture password', 'MACOS_SIGNING_CERTIFICATE_SHA1':'b'*40}
        event = self.root/'event.json'; event.write_text('{"inputs":{"tag":"v0.6.13","mode":"mac-trial","expected_sha":"'+ 'a'*40 +'"}}')
        self.environment['GITHUB_EVENT_PATH']=str(event)

    def runner(self, command):
        self.calls.append(command)
        self.assertEqual(command[0],'/usr/bin/security')
        if command[1]=='list-keychains': return 'fixture original list'
        keychain = self.root/'keepresso-project-signing/signing.keychain-db'
        if command[1]=='create-keychain': keychain.touch()
        if command[1]=='import' and self.fail_import: raise ValueError('fixture import refused')
        if command[1]=='delete-keychain': keychain.unlink(missing_ok=True)
        return ''

    def package(self, input_zip, output_zip, sha1, keychain, source):
        self.packed = True
        self.assertEqual(sha1,'b'*40); self.assertEqual(source,'a'*40)
        self.assertEqual(keychain.stat().st_mode & 0o777,0o600)
        root = keychain.parent
        self.assertEqual(root.stat().st_mode & 0o777,0o700)
        self.assertEqual((root/'identity.p12').stat().st_mode & 0o777,0o600)
        self.assertNotIn('MACOS_SIGNING_PKCS12_PASSWORD',os.environ)
        return {'sha256':'fixture'}

    def sign(self):
        return ci.sign('candidate.zip','signed.zip','a'*40,self.environment,runner=self.runner,packager=self.package)

    def test_private_import_exact_signer_and_unconditional_cleanup(self):
        self.assertEqual(self.sign(),{'sha256':'fixture'})
        self.assertTrue(self.packed)
        command = next(c for c in self.calls if c[1]=='import')
        self.assertEqual(command[-2:],['-T','/usr/bin/codesign'])
        self.assertFalse((self.root/'keepresso-project-signing').exists())
        self.assertEqual([c[1] for c in self.calls].count('delete-keychain'),1)

    def test_invalid_config_is_refused_before_touching_keychain(self):
        for key,value in [('MACOS_SIGNING_PKCS12_BASE64','!bad'),('MACOS_SIGNING_PKCS12_PASSWORD','short'),
                          ('MACOS_SIGNING_CERTIFICATE_SHA1','name'),('GITHUB_SHA','c'*40),('GITHUB_EVENT_NAME','pull_request')]:
            previous=self.environment[key]; self.environment[key]=value
            with self.subTest(key=key), self.assertRaises(ValueError): self.sign()
            self.environment[key]=previous
        self.assertFalse(self.calls); self.assertFalse(self.packed)

    def test_import_failure_cleans_key_and_keychain(self):
        self.fail_import=True
        with self.assertRaises(ValueError): self.sign()
        self.assertFalse(self.packed); self.assertFalse((self.root/'keepresso-project-signing').exists())
        self.assertTrue(any(c[1]=='delete-keychain' for c in self.calls))

    def test_package_failure_also_cleans(self):
        def failed(*args): raise ValueError('fixture signer refused')
        with self.assertRaises(ValueError):
            ci.sign('candidate.zip','signed.zip','a'*40,self.environment,runner=self.runner,packager=failed)
        self.assertFalse((self.root/'keepresso-project-signing').exists())


if __name__=='__main__':unittest.main()

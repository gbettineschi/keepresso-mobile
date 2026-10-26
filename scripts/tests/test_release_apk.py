import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("apk", Path(__file__).parents[1] / "verify-release-apk.py")
apk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(apk)


class ApkIdentityTests(unittest.TestCase):
    def test_signing_and_version_must_match_retained_identity(self):
        certificate = 'a' * 64
        signed = f'Signer #1 certificate SHA-256 digest: {certificate}\n'
        identity = "package: name='io.github.gbettineschi.keepressomobile' versionCode='4003' versionName='0.4.3'"
        apk.verify_identity(signed, identity, certificate, '0.4.3', 4003)
        for cert, package in [('b' * 64, identity), (certificate, identity.replace('4003', '5')),
                              (certificate, identity.replace('keepressomobile', 'other'))]:
            with self.assertRaises(ValueError):
                apk.verify_identity(signed, package, cert, '0.4.3', 4003)

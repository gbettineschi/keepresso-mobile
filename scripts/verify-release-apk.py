#!/usr/bin/env python3
"""Check the published Android identity against the retained owner's signing key."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

OWNER_CERTIFICATE = "166dd4da449dcccaa1e4e1b881bf77455c38f6633809aeba53480034a0b2395d"


def verify_identity(certificate_output, badging, certificate, version, code):
    digests = re.findall(r"certificate SHA-256 digest: ([0-9a-f]+)", certificate_output)
    if digests != [certificate]:
        raise ValueError("APK does not use the retained owner's signing certificate.")
    identity = re.search(r"package: name='([^']+)' versionCode='([^']+)' versionName='([^']+)'", badging)
    if not identity or identity.groups() != ("io.github.gbettineschi.keepressomobile", str(code), version):
        raise ValueError("APK package or version differs from the tagged release.")


if __name__ == "__main__":
    apk, version, code = Path(sys.argv[1]), sys.argv[2], int(sys.argv[3])
    tools = Path(os.environ['ANDROID_HOME']) / 'build-tools' / '35.0.0'
    cert = subprocess.check_output(['keytool', '-exportcert', '-keystore', os.environ['KEEPRESSO_SIGNING_STORE'],
                                    '-alias', os.environ['KEEPRESSO_SIGNING_ALIAS'],
                                    '-storepass:env', 'KEEPRESSO_SIGNING_PASSWORD'])
    digest = hashlib.sha256(cert).hexdigest()
    if digest != OWNER_CERTIFICATE:
        raise ValueError("Configured key differs from the retained owner signing identity.")
    signed = subprocess.check_output([str(tools/'apksigner'), 'verify', '--print-certs', str(apk)], text=True)
    badging = subprocess.check_output([str(tools/'aapt'), 'dump', 'badging', str(apk)], text=True)
    verify_identity(signed, badging, digest, version, code)
    print(json.dumps({'version': version, 'androidVersionCode': code, 'androidCertificateSha256': digest,
                      'sourceCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()}, indent=2))

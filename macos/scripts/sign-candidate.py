#!/usr/bin/env python3
"""Validate and sign a keyless-built companion ZIP. Never execute the candidate."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import stat
import struct
import subprocess
import tempfile
import unicodedata
import zipfile

ROOT = 'KeepressoMobile.app'
IDENTIFIER = 'local.keespresso.companion'
MAIN = 'Contents/MacOS/KeepressoMac'
LIMIT = 256 * 1024 * 1024
MAGIC = {bytes.fromhex(value) for value in ('cffaedfe','feedfacf','cefaedfe','feedface','cafebabe','bebafeca','cafebabf','bfbafeca')}
PRIVATE_SUFFIXES = ('.p12','.pfx','.keychain','.keychain-db','.key','.pem')


def execute(command, *, env=None):
    result = subprocess.run(command, env=env, text=True, capture_output=True)
    if result.returncode:
        raise ValueError('Signature validation or signing failed (exit %s)' % result.returncode)
    return result.stdout + result.stderr


def preflight_directory(archive):
    # ZipFile eagerly allocates a ZipInfo per directory entry. Bound that input
    # before asking it to parse anything, including a falsely small entry count.
    size = archive.stat().st_size
    with archive.open('rb') as source:
        source.seek(max(0, size - 65_557))
        tail = source.read(65_557)
    position = tail.rfind(b'PK\x05\x06')
    if position < 0 or position + 22 > len(tail): raise ValueError('Missing ZIP directory trailer')
    _, disk, directory_disk, disk_entries, entries, length, offset, comment = struct.unpack_from('<4s4H2IH', tail, position)
    trailer = size - len(tail) + position
    if position + 22 + comment != len(tail) or disk or directory_disk or disk_entries != entries:
        raise ValueError('Unsupported split or ambiguous ZIP archive')
    if not 0 < entries <= 4096 or not 0 < length <= 1024 * 1024 or offset == 0xffffffff or offset + length != trailer:
        raise ValueError('Oversized directory or unsupported ZIP64 archive')


def extract_candidate(archive, directory):
    if archive.is_symlink() or not archive.is_file() or archive.stat().st_size > LIMIT:
        raise ValueError('Missing, linked or oversized candidate archive')
    preflight_directory(archive)
    seen, total = set(), 0
    with zipfile.ZipFile(archive) as z:
        entries=z.infolist()
        if len(entries)>4096: raise ValueError('Too many archive entries')
        for item in entries:
            name=item.filename
            path=PurePosixPath(name)
            normalized=str(path)
            if '\x00' in item.orig_filename or '\\' in name or path.is_absolute() or '..' in path.parts or normalized!=name.rstrip('/'):
                raise ValueError('Unsafe archive path')
            canonical=unicodedata.normalize('NFC',name.rstrip('/')).casefold()
            if canonical in seen: raise ValueError('Duplicate or case-colliding archive path')
            seen.add(canonical)
            total+=item.file_size
            if total>LIMIT: raise ValueError('Expanded candidate is too large')
            mode=item.external_attr >> 16
            if stat.S_IFMT(mode) not in (0,stat.S_IFREG,stat.S_IFDIR): raise ValueError('Linked or special archive member')
            if item.flag_bits & 1: raise ValueError('Encrypted candidate member')
            if item.extract_version > 20 or item.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
                raise ValueError('Unsupported ZIP member format')
            if path.parts and path.parts[0]=='__MACOSX': continue
            if not path.parts or path.parts[0]!=ROOT: raise ValueError('Expected one companion app')
            target=directory.joinpath(*path.parts)
            if item.is_dir():
                target.mkdir(parents=True,exist_ok=True);target.chmod(0o755);continue
            if name.lower().endswith(PRIVATE_SUFFIXES): raise ValueError('Key material does not belong in an app artifact')
            target.parent.mkdir(parents=True,exist_ok=True)
            with z.open(item) as source, target.open('xb') as output:
                copied=0
                while chunk:=source.read(1024*1024):
                    copied+=len(chunk)
                    if copied>item.file_size or copied>LIMIT: raise ValueError('Invalid member size')
                    output.write(chunk)
            target.chmod(0o755 if name==ROOT+'/'+MAIN else 0o644)
    app=directory/ROOT
    info_path=app/'Contents/Info.plist'
    if not info_path.is_file() or info_path.stat().st_size>65536: raise ValueError('Missing or oversized app information')
    with info_path.open('rb') as f: info=plistlib.load(f)
    if info.get('CFBundleIdentifier')!=IDENTIFIER or info.get('CFBundleExecutable')!='KeepressoMac' or info.get('CFBundlePackageType')!='APPL':
        raise ValueError('Unexpected app identity or executable')
    version=info.get('CFBundleShortVersionString','');build=info.get('CFBundleVersion','')
    if not isinstance(version,str) or len(version)>32 or re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+',version) is None or not isinstance(build,str) or re.fullmatch(r'[0-9]{1,12}',build) is None:
        raise ValueError('Unexpected app version')
    executable=app/MAIN
    if not executable.is_file(): raise ValueError('Missing companion executable')
    for file in app.rglob('*'):
        if not file.is_file(): continue
        with file.open('rb') as f: magic=f.read(4)
        relative=file.relative_to(app).as_posix()
        if relative==MAIN:
            if magic not in MAGIC: raise ValueError('Companion executable must be Mach-O')
        elif magic in MAGIC or relative.startswith('Contents/MacOS/'):
            raise ValueError('Unexpected nested executable; requires an explicit signing policy')
    return app,version,build


def sign_candidate(input_zip, output_zip, certificate_sha1, keychain, source_sha, *, runner=execute):
    input_zip, output_zip, keychain = Path(input_zip), Path(output_zip), Path(keychain)
    if re.fullmatch(r'[0-9a-fA-F]{40}',certificate_sha1) is None or re.fullmatch(r'[0-9a-f]{40}',source_sha) is None:
        raise ValueError('Expected exact certificate and source fingerprints')
    if output_zip.exists() or output_zip.is_symlink() or not output_zip.parent.is_dir():
        raise ValueError('Output must be a new archive in an existing directory')
    if keychain.is_symlink() or not keychain.is_file(): raise ValueError('Explicit temporary signing keychain is unavailable')
    try:
        with tempfile.TemporaryDirectory(prefix='keepresso-sign-only-') as temporary:
            root=Path(temporary);root.chmod(0o700)
            app,version,build=extract_candidate(input_zip,root)
            runner(['codesign','--verify','--deep','--strict','--test-requirement', '=identifier "'+IDENTIFIER+'"',str(app)])
            env={k:v for k,v in os.environ.items() if not k.startswith('MACOS_SIGNING_') and k not in ('KEEPRESSO_SIGNING_PASSWORD','KEEPRESSO_SIGNING_KEY_PASSWORD')}
            env.update(KEEPRESSO_SIGNING_PROFILE='project',KEEPRESSO_REQUIRE_STABLE_SIGNING='1',KEEPRESSO_CODESIGN_IDENTITY=certificate_sha1,
                       KEEPRESSO_CODESIGN_KEYCHAIN=str(keychain))
            runner(['bash',str(Path(__file__).with_name('sign-app.sh')),str(app)],env=env)
            runner(['codesign','--verify','--deep','--strict','--test-requirement',
                    '=identifier "'+IDENTIFIER+'" and certificate leaf = H"'+certificate_sha1+'"',str(app)])
            shown=runner(['codesign','--display','-r-',str(app)])
            requirements=[line.removeprefix('designated => ') for line in shown.splitlines() if line.startswith('designated => ')]
            expected='identifier "'+IDENTIFIER+'" and certificate leaf = H"'+certificate_sha1.lower()+'"'
            if requirements!=[expected]: raise ValueError('Project designated requirement changed or is too broad')
            packed=root/'signed.zip'
            with zipfile.ZipFile(packed,'w',zipfile.ZIP_DEFLATED) as z:
                for file in sorted(app.rglob('*')):
                    if file.is_file():z.write(file,file.relative_to(root).as_posix())
            digest=hashlib.sha256(packed.read_bytes()).hexdigest()
            # Same-filesystem staging prevents publishing a partial archive on failure.
            with tempfile.NamedTemporaryFile(prefix='.keepresso-signed-',dir=output_zip.parent,delete=False) as staged:
                stage=Path(staged.name)
                try:
                    with packed.open('rb') as source:
                        while chunk:=source.read(1024*1024):staged.write(chunk)
                    staged.flush();os.fsync(staged.fileno())
                    # Atomic publication must never replace another job's archive.
                    os.link(stage,output_zip)
                finally:stage.unlink(missing_ok=True)
            return {'version':version,'build':build,'sourceCommit':source_sha,'certificateSha1':certificate_sha1.lower(),
                    'designatedRequirement':expected,'sha256':digest}
    except (OSError,zipfile.BadZipFile,plistlib.InvalidFileException,RuntimeError) as error:
        raise ValueError('Candidate packaging failed: '+str(error)) from error


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input_zip',type=Path);parser.add_argument('output_zip',type=Path)
    parser.add_argument('--certificate-sha1',required=True);parser.add_argument('--keychain',type=Path,required=True)
    parser.add_argument('--source-sha',required=True)
    args=parser.parse_args()
    try: result=sign_candidate(args.input_zip,args.output_zip,args.certificate_sha1,args.keychain,args.source_sha)
    except ValueError as error:parser.exit(2,str(error)+'\n')
    print(json.dumps(result,indent=2))

if __name__=='__main__':main()

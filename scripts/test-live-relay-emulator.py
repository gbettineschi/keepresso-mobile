#!/usr/bin/env python3
"""Opt-in real HTTPS + Android service + synthetic Swift Mac; never native power.
Requires prebuilt debug/test APKs and the private relay bearer file. Fixture phone
keys are seeded in a cleared, explicitly validated disposable Keepresso_ AVD.
"""
import argparse,base64,json,os,re,subprocess,time,uuid
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--adb',required=True);p.add_argument('--client',required=True);p.add_argument('--url',required=True);p.add_argument('--mac-bearer',required=True);p.add_argument('--private-dir',required=True)
a=p.parse_args();root=Path(__file__).resolve().parent.parent;package='io.github.gbettineschi.keepressomobile'
def adb(*args,**kwargs):return subprocess.run([a.adb,'-s',a.client,*args],check=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,**kwargs)
assert re.fullmatch(r'emulator-\d+',a.client),'Physical phones are forbidden'
assert adb('shell','getprop','ro.hardware',text=True).stdout.strip()=='ranchu'
assert adb('emu','avd','name',text=True).stdout.startswith('Keepresso_')
directory=Path(a.private_dir).resolve();directory.mkdir(mode=0o700,parents=True,exist_ok=False)
config={'macId':str(uuid.uuid4()),'deviceId':str(uuid.uuid4()),'key':base64.b64encode(os.urandom(32)).decode(),'url':a.url,'bearerPath':str(Path(a.mac_bearer).resolve())}
config_path=directory/'config.json';config_path.write_text(json.dumps(config));config_path.chmod(0o600)
env=dict(os.environ,KEEPRESSO_LIVE_FIXTURE_CONFIG=str(config_path))
with (directory/'swift.log').open('w') as log:
    process=subprocess.Popen(['swift','test','--package-path','macos','--filter','LiveRelayFixtureTests'],cwd=root,env=env,stdout=log,stderr=subprocess.STDOUT)
    try:
        for _ in range(90):
            if (directory/'phone.json').exists():break
            if process.poll() is not None:raise RuntimeError('Swift fixture exited; inspect its log')
            time.sleep(1)
        else:raise RuntimeError('Swift fixture did not become ready')
        for apk in ['debug/app-debug.apk','androidTest/debug/app-debug-androidTest.apk']:adb('install','-r',str(root/'android/app/build/outputs/apk'/apk))
        adb('shell','am','force-stop',package);adb('shell','pm','clear',package)
        adb('shell','run-as',package,'mkdir','-p','files')
        adb('shell','run-as',package,'sh','-c',"'cat > files/live-phone.json'",input=(directory/'phone.json').read_bytes())
        result=adb('shell','am','instrument','-w','-r','-e','class',package+'.LiveRelayTest','-e','liveRelay','true',package+'.test/androidx.test.runner.AndroidJUnitRunner',text=True).stdout
        (directory/'android.log').write_text(result)
        assert re.search(r'OK \(1 test\)',result),'Android live flow failed; inspect android.log'
        report=adb('exec-out','run-as',package,'cat','cache/live-report.json',text=True).stdout
        (directory/'android-report.json').write_text(report)
        print(report,flush=True)
    finally:
        (directory/'done').touch()
        try:process.wait(timeout=25)
        except subprocess.TimeoutExpired:process.terminate();process.wait(timeout=10)
        adb('shell','am','force-stop',package)
    assert process.returncode==0,'Swift fixture did not pass/revoke; inspect swift.log'
    print((directory/'mac-report.json').read_text(),flush=True)

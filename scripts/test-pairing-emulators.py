#!/usr/bin/env python3
"""Exercise Android pairing using two disposable Keepresso virtual devices only."""
import argparse, re, shutil, subprocess, threading, time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

root=Path(__file__).resolve().parent.parent
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--adb',default='adb')
parser.add_argument('--client',required=True)
parser.add_argument('--peer',required=True)
parser.add_argument('--netsim',help='Emulator radio-control executable (default: sibling SDK emulator/netsim)')
parser.add_argument('--case',choices=['all','approve','deny','slow'],default='all',help='Run the full suite or one focused Bluetooth flow')
args=parser.parse_args()
if args.client==args.peer:parser.error('Client and peer must be different emulators')
package='io.github.gbettineschi.keepressomobile'
results=root/'android/app/build/emulator-results';results.mkdir(parents=True,exist_ok=True)

def adb(serial,*arguments,check=True):
    return subprocess.run([args.adb,'-s',serial,*arguments],check=check,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT).stdout

avds={}
for serial in [args.client,args.peer]:
    if not re.fullmatch(r'emulator-\d+',serial):parser.error('Physical phones are forbidden')
    if adb(serial,'shell','getprop','ro.hardware').strip()!='ranchu':parser.error('Expected a virtual device')
    avds[serial]=adb(serial,'emu','avd','name').splitlines()[0]
    if not avds[serial].startswith('Keepresso_'):parser.error('Use dedicated Keepresso_ AVDs; other virtual devices are forbidden')
    if 'state: ON' not in adb(serial,'shell','dumpsys','bluetooth_manager'):
        adb(serial,'shell','svc','bluetooth','enable')
        for _ in range(40):
            if 'state: ON' in adb(serial,'shell','dumpsys','bluetooth_manager'):break
            time.sleep(.25)
        else:parser.error('Bluetooth is unavailable inside '+serial+'; cold-boot that disposable AVD before testing')
netsim=args.netsim or str(Path(shutil.which(args.adb) or args.adb).resolve().parent.parent/'emulator/netsim')
if not Path(netsim).is_file():parser.error('Locate emulator/netsim with --netsim')

def radio(status):
    # Only the separately validated synthetic peer's BLE radio is affected.
    subprocess.run([netsim,'radio','ble',status,avds[args.peer]],check=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)

def link_loss(stop):
    while not stop.wait(0.3):
        if 'LINK_LOSS' in adb(args.peer,'logcat','-d','-s','KeepressoVirtualPeer'):
            try:radio('down');stop.wait(8)
            finally:radio('up')
            return
    raise RuntimeError('The synthetic trigger refresh never requested a link-loss test')

print('Building emulator tests',flush=True)
with (results/'build.log').open('w') as log:
    subprocess.run([str(root/'android/gradlew'),'--no-daemon',':core:test',':app:assembleDebug',':app:assembleDebugAndroidTest'],cwd=root/'android',check=True,stdout=log,stderr=subprocess.STDOUT)
for serial in [args.client,args.peer]:
    for apk in ['debug/app-debug.apk','androidTest/debug/app-debug-androidTest.apk']:
        adb(serial,'install','-r',str(root/'android/app/build/outputs/apk'/apk))

def clear_client():
    adb(args.client,'shell','am','force-stop',package)
    adb(args.client,'shell','pm','clear',package)

def test(name,method,mode=None):
    print(name,flush=True)
    command=['shell','am','instrument','-w','-r','-e','class',package+'.'+method]
    if mode:command+=['-e','virtualPeer',mode]
    output=adb(args.client,*command,package+'.test/androidx.test.runner.AndroidJUnitRunner')
    (results/(name+'.log')).write_text(output)
    if not re.search(r'OK \(\d+ tests?\)',output):raise RuntimeError(name+' failed:\n'+output[-5000:])

adb(args.peer,'shell','am','force-stop',package)
if args.case=='all':
    clear_client()
    test('permission','PairingPermissionTest#scannedInvitationContinuesAfterNearbyPermissionApproval')
    clear_client()
    test('permission-recreation','PairingPermissionTest#scannedInvitationSurvivesActivityRecreation')
    test('screen','PairingScreenTest')
    test('dashboard','DashboardUiTest')
    clear_client()
    test('transport-state','TransportStateTest')

def peer_case(mode,method):
    clear_client();adb(args.peer,'shell','am','force-stop',package);adb(args.peer,'logcat','-c')
    log=(results/('peer-'+mode+'.log')).open('w')
    command=[args.adb,'-s',args.peer,'shell','am','instrument','-w','-r','-e','class',package+'.VirtualMacPeerTest','-e','virtualPeer','true','-e','mode',mode,package+'.test/androidx.test.runner.AndroidJUnitRunner']
    process=subprocess.Popen(command,stdout=log,stderr=subprocess.STDOUT)
    stop=threading.Event();executor=ThreadPoolExecutor(max_workers=1);outage=None
    try:
        for _ in range(25):
            if 'READY' in adb(args.peer,'logcat','-d','-s','KeepressoVirtualPeer'):break
            if process.poll() is not None:raise RuntimeError('Virtual peer exited; inspect '+str(results/('peer-'+mode+'.log')))
            time.sleep(1)
        else:raise RuntimeError('Virtual Bluetooth advertiser did not become ready')
        if mode=='approve':outage=executor.submit(link_loss,stop)
        test('flow-'+mode,method,'deny' if mode=='deny' else 'true')
        if outage is not None:outage.result(timeout=15)
        if mode=='approve':
            screenshot=subprocess.check_output([args.adb,'-s',args.client,'exec-out','run-as',package,'cat','cache/pairing-flow.png'])
            (results/'pairing-flow.png').write_bytes(screenshot)
    finally:
        stop.set();executor.shutdown(wait=True)
        adb(args.peer,'shell','am','force-stop',package,check=False)
        try:process.wait(timeout=5)
        except subprocess.TimeoutExpired:process.terminate();process.wait(timeout=5)
        log.close()

if args.case in ['all','approve']:peer_case('approve','PairingFlowTest#qrApprovalEncryptedDashboardControlsAndReconnect')
if args.case in ['all','deny']:peer_case('deny','PairingFlowTest#localDenialDoesNotPersistPhoneAuthorization')
if args.case in ['all','slow']:peer_case('slow','PairingFlowTest#quietPollKeepsControlsEnabledAndTapWaitsBehindReadWithoutDuplicates')
print('PASS: '+args.case+' pairing emulator checks. Results: '+str(results),flush=True)

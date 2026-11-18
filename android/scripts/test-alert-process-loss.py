#!/usr/bin/env python3
"""Two-stage debug fixture; refuses physical devices before any mutation."""
import argparse
import os
import subprocess
import shlex
import time

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--serial", required=True)
p.add_argument("--mode", choices=("awake", "doze", "reboot", "critical", "snooze"), default="awake")
p.add_argument("--wait", type=int, default=120)
args = p.parse_args()
adb = os.path.join(os.environ["ANDROID_HOME"], "platform-tools", "adb")
package = "io.github.gbettineschi.keepressomobile"

def call(*parts, check=True):
    command = ["shell", shlex.join(parts[1:])] if parts and parts[0] == "shell" else list(parts)
    return subprocess.run([adb, "-s", args.serial, *command], check=check, text=True, capture_output=True).stdout.strip()

if call("shell", "getprop", "ro.hardware") != "ranchu":
    raise SystemExit("Refusing to mutate a physical device; an explicit ranchu emulator is required")

def fixture(method):
    result = call("shell", "am", "instrument", "-w", "-r", "-e", "class",
                  f"{package}.AlertProcessFixtureTest#{method}", f"{package}.test/androidx.test.runner.AndroidJUnitRunner")
    if "OK (1 test)" not in result:
        raise RuntimeError(result)

def cards():
    keys = call("shell", "cmd", "notification", "list").splitlines()
    return "\n".join(call("shell", "cmd", "notification", "get", key) for key in keys if package in key)

try:
    fixture({"critical": "prepareCritical", "snooze": "prepareSnoozedCritical"}.get(args.mode, "prepareAwake"))
    # Instrumentation has completed. SIGKILL is deliberately distinct from Android force-stop.
    pid = call("shell", "pidof", package, check=False)
    if pid:
        for value in pid.split():
            if not value.isdigit():
                raise RuntimeError("Unexpected process identifier")
            call("shell", "run-as", package, "kill", "-9", value)
    start = time.monotonic()
    if args.mode == "doze":
        call("shell", "dumpsys", "battery", "unplug")
        call("shell", "dumpsys", "deviceidle", "force-idle", "deep")
    if args.mode == "reboot":
        call("reboot"); call("wait-for-device")
        while call("shell", "getprop", "sys.boot_completed") != "1":
            if time.monotonic() - start > args.wait: raise RuntimeError("Emulator boot timed out")
            time.sleep(1)
        call("shell", "input", "keyevent", "82")
    if args.mode == "critical":
        # More than the old five-minute cap, without starting the app again.
        time.sleep(310)
        text = cards()
        if "keepresso.critical." not in text or "INSISTENT" not in text:
            raise RuntimeError("System-owned Critical warning did not survive five minutes/process loss")
    else:
        expected = "keepresso.critical." if args.mode == "snooze" else "Your Mac was running with the screen off"
        while expected not in cards():
            if time.monotonic() - start > args.wait: raise RuntimeError("Deferred OS fallback not observed within test window")
            time.sleep(1)
        print(f"OS fallback observed after {time.monotonic() - start:.1f}s ({args.mode})", flush=True)
    fixture("verifyCritical" if args.mode in ("critical", "snooze") else "verifyHistory")
finally:
    if args.mode == "doze":
        call("shell", "dumpsys", "deviceidle", "unforce", check=False)
        call("shell", "dumpsys", "battery", "reset", check=False)
    fixture("cleanup")

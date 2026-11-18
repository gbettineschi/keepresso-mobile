#!/usr/bin/env python3
"""Run bursty notification fixtures on an explicitly selected emulator only."""
import argparse
import os
import shlex
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--serial", required=True)
p.add_argument("--classes", default="AwakeAlertLifecycleTest,IncidentAlertTest,CriticalAlarmLifecycleTest")
args = p.parse_args()
adb = os.path.join(os.environ["ANDROID_HOME"], "platform-tools", "adb")

def call(*parts):
    command = ["shell", shlex.join(parts[1:])] if parts[0] == "shell" else list(parts)
    return subprocess.run([adb, "-s", args.serial, *command], check=True, capture_output=True, text=True).stdout.strip()

if call("shell", "getprop", "ro.hardware") != "ranchu":
    raise SystemExit("These permission/notification fixtures require the isolated ranchu emulator")
old = call("shell", "settings", "get", "global", "max_notification_enqueue_rate")
try:
    # Fixtures deliberately compress hours of evidence into seconds; avoid OS rate shedding.
    call("shell", "settings", "put", "global", "max_notification_enqueue_rate", "100")
    classes = ",".join("io.github.gbettineschi.keepressomobile." + name for name in args.classes.split(","))
    result = call("shell", "am", "instrument", "-w", "-r", "-e", "class", classes,
                  "io.github.gbettineschi.keepressomobile.test/androidx.test.runner.AndroidJUnitRunner")
    print(result)
    if "OK (" not in result or "FAILURES" in result:
        raise SystemExit(1)
finally:
    if old == "null":
        call("shell", "settings", "delete", "global", "max_notification_enqueue_rate")
    else:
        call("shell", "settings", "put", "global", "max_notification_enqueue_rate", old)

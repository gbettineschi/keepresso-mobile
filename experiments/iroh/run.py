#!/usr/bin/env python3
"""Bounded read-only Swift ↔ Android trial. Physical devices need explicit opt-in."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import subprocess
import time
import zipfile

ROOT = Path(__file__).resolve().parent
PACKAGE = "io.github.gbettineschi.keepressomobile.irohtrial"


def run(command, **kwargs):
    return subprocess.run(command, check=True, text=True, capture_output=True, **kwargs)


def stop(process):
    if process is not None and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=8)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", type=Path, required=True)
    parser.add_argument("--serial", default="emulator-5584")
    parser.add_argument("--physical-device", action="store_true",
        help="Authorize installation/instrumentation of the separate trial package on the exact --serial")
    parser.add_argument("--run-label", help="Optional local result directory label; no device identifiers")
    parser.add_argument("--avd")
    parser.add_argument("--avd-home", type=Path)
    parser.add_argument("--mode", choices=["direct", "auto", "relay", "both"], default="both")
    parser.add_argument("--case", help="Run one named instrumentation case for diagnosis")
    args = parser.parse_args()
    virtual_serial = re.fullmatch(r"emulator-[0-9]+", args.serial) is not None
    if args.physical_device:
        if virtual_serial or not re.fullmatch(r"[A-Za-z0-9._:-]+", args.serial):
            parser.error("Physical trials require an explicit physical --serial")
        if args.avd or args.avd_home or args.mode == "direct":
            parser.error("Physical trials use auto/relay modes and never emulator shortcuts")
    elif not virtual_serial:
        parser.error("Physical devices require --physical-device and an explicit --serial")
    if args.run_label and not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,40}", args.run_label):
        parser.error("Invalid result-directory label")
    if args.case and not re.fullmatch(r"[A-Za-z]+", args.case):
        parser.error("Invalid instrumentation case name")
    expected_tests = 1 if args.case else 9
    adb = str(args.sdk / "platform-tools/adb")
    base = [adb, "-s", args.serial]
    output = ROOT / ".run"
    if args.run_label or args.physical_device:
        output /= args.run_label or "physical"
    output.mkdir(parents=True, exist_ok=True)
    apk = ROOT / "android/probe/build/outputs/apk/debug/probe-debug.apk"
    test_apk = ROOT / "android/probe/build/outputs/apk/androidTest/debug/probe-debug-androidTest.apk"
    bin_dir = run(["swift", "build", "--package-path", str(ROOT / "swift"),
        "-c", "release", "--show-bin-path"], timeout=30).stdout.strip()
    binary = Path(bin_dir) / "IrohTrial"
    for path in [apk, test_apk, binary]:
        if not path.is_file():
            raise RuntimeError(f"Build the trial first: missing {path.relative_to(ROOT)}")
    emulator = None
    summary = {"bindingVersion": "1.2.0", "syntheticFixturesOnly": True,
        "deviceType": "physical" if args.physical_device else "emulator",
        "startedAt": datetime.now(timezone.utc).isoformat(), "status": "running", "runs": []}
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    try:
        devices = run([adb, "devices"]).stdout.splitlines()
        present = any(line.startswith(args.serial + "\tdevice") for line in devices)
        if not present:
            if args.physical_device:
                raise RuntimeError("The explicitly selected phone is not connected and authorized")
            if not args.avd or not args.avd_home:
                raise RuntimeError("Start an emulator or provide --avd and --avd-home")
            env = dict(os.environ, ANDROID_AVD_HOME=str(args.avd_home), ANDROID_SDK_ROOT=str(args.sdk))
            with (output / "emulator.log").open("w") as log:
                emulator = subprocess.Popen([str(args.sdk / "emulator/emulator"), "-avd", args.avd,
                    "-port", args.serial.split("-")[1], "-read-only", "-no-window",
                    "-no-audio", "-no-boot-anim", "-no-snapshot-save"], env=env, stdout=log, stderr=log)
            deadline = time.monotonic() + 100
            while time.monotonic() < deadline:
                if emulator.poll() is not None:
                    raise RuntimeError("Emulator exited; inspect .run/emulator.log")
                try:
                    if run(base + ["shell", "getprop", "sys.boot_completed"], timeout=3).stdout.strip() == "1":
                        break
                except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
                    pass
                time.sleep(1)
            else:
                raise RuntimeError("Emulator did not boot within 100 seconds")
        is_emulator = run(base + ["shell", "getprop", "ro.kernel.qemu"]).stdout.strip() == "1"
        if is_emulator == args.physical_device:
            raise RuntimeError("Device type does not match the explicitly requested trial mode")
        if args.physical_device:
            summary["model"] = run(base + ["shell", "getprop", "ro.product.model"]).stdout.strip()
        run(base + ["install", "-r", str(apk)], timeout=60)
        run(base + ["install", "-r", str(test_apk)], timeout=60)
        summary["apkBytes"] = apk.stat().st_size
        with zipfile.ZipFile(apk) as archive:
            summary["nativeLibraries"] = [{"name": i.filename, "bytes": i.file_size}
                for i in archive.infolist() if i.filename.startswith("lib/")]
        modes = (["auto", "relay"] if args.physical_device else ["direct", "relay"]) if args.mode == "both" else [args.mode]
        for mode in modes:
            config = output / f"{mode}-endpoint.json"
            config.unlink(missing_ok=True)
            (output / f"{mode}-android.log").unlink(missing_ok=True)
            fixture = None
            try:
                with (output / f"{mode}-mac.log").open("w") as log:
                    fixture = subprocess.Popen([str(binary), mode, str(config)], stdout=log, stderr=log)
                deadline = time.monotonic() + 40
                while not config.exists() and time.monotonic() < deadline:
                    if fixture.poll() is not None:
                        raise RuntimeError(f"{mode} Mac fixture exited; inspect its log")
                    time.sleep(0.2)
                if not config.exists():
                    raise RuntimeError(f"{mode} Mac fixture did not become ready within 40 seconds")
                public_config = json.loads(config.read_text())
                samples = []
                for _ in range(5):
                    fields = run(["ps", "-p", str(fixture.pid), "-o", "rss=", "-o", "time="]).stdout.split()
                    samples.append({"rssKiB": int(fields[0]), "cpuTime": fields[1]})
                    time.sleep(1)
                started = time.monotonic()
                result = subprocess.run(base + ["shell", "am", "instrument", "-w", "-r",
                    "-e", "class", PACKAGE + ".ConnectivityTrial" + ("#" + args.case if args.case else ""),
                    "-e", "mode", mode, "-e", "ticket", public_config["ticket"],
                    "-e", "allowPhysical", "true" if args.physical_device else "false",
                    PACKAGE + ".test/androidx.test.runner.AndroidJUnitRunner"],
                    check=False, text=True, capture_output=True, timeout=240)
                (output / f"{mode}-android.log").write_text(result.stdout + result.stderr)
                if result.returncode != 0:
                    raise RuntimeError(f"Android instrumentation exited with code {result.returncode}; inspect the local {mode} log")
                if not re.search(r"OK \(" + str(expected_tests) + r" tests?\)", result.stdout) or "FAILURES!!!" in result.stdout:
                    raise RuntimeError(f"{mode} tests failed; inspect .run/{mode}-android.log")
                metrics = re.search(r"IROH_TRIAL mode=" + mode + r" samples=(\d+) medianMs=(\d+) maxMs=(\d+)", result.stdout)
                if not metrics and not args.case:
                    raise RuntimeError("Successful tests did not return the trial measurements")
                summary["runs"].append({"mode": mode, "tests": expected_tests,
                    **({"roundTrips": int(metrics[1]), "medianMs": int(metrics[2]), "maxMs": int(metrics[3])} if metrics else {}),
                    **({"selectedPath": path[1], "phoneNetwork": path[2]} if (path := re.search(r" path=([a-z+]+) network=([a-z]+)", result.stdout)) else {}),
                    "elapsedSeconds": round(time.monotonic() - started, 3), "macIdleSamples": samples})
                (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
                print(f"{mode}: {expected_tests} tests passed", flush=True)
            finally:
                stop(fixture)
                config.unlink(missing_ok=True)
        summary["status"] = "passed"
        print(f"Results saved in {output.relative_to(ROOT)}/summary.json", flush=True)
    except BaseException as error:
        summary["status"] = "failed"
        # Command arguments can contain a public endpoint ticket with network
        # addresses. Keep them out of the portable summary, including on failure.
        summary["failure"] = ("Trial subprocess timed out" if isinstance(error, subprocess.TimeoutExpired)
            else f"Trial subprocess exited with code {error.returncode}" if isinstance(error, subprocess.CalledProcessError)
            else str(error))
        raise
    finally:
        stop(emulator)
        (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")


if __name__ == "__main__":
    main()

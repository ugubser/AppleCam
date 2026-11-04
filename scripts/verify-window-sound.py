#!/usr/bin/env python3
"""Opt-in check of window-layer sound: AppleCam's AppSoundTap captures a stand-in app (and a helper it starts later)
with a muted Core Audio tap.

Needs System Audio Recording permission for the harness (macOS asks the first time). Set APPLECAM_SIGNING_IDENTITY to
a code-signing identity so that permission survives rebuilds. With --microphone (run from a terminal that may use the
microphone), the microphone also measures the tones in each phase, to show the speakers are quiet while tapped.
"""
import os
import plistlib
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORK = ROOT / "work"
IDENTITY = os.environ.get("APPLECAM_SIGNING_IDENTITY", "-")


def bundle(path, identifier, name, executable, sources, extra=None, helper=None):
    macos = path / "Contents/MacOS"
    macos.mkdir(parents=True, exist_ok=True)
    info = {"CFBundleIdentifier": identifier, "CFBundleExecutable": executable, "CFBundlePackageType": "APPL",
            "CFBundleName": name, "LSMinimumSystemVersion": "15.2", **(extra or {})}
    (path / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    subprocess.run(["swiftc", "-parse-as-library", "-target", "arm64-apple-macos15.2", *map(str, sources), "-o", str(macos / executable)], cwd=ROOT, check=True)
    if helper:
        helper(path)
    subprocess.run(["codesign", "-f", "-s", IDENTITY, "--deep", str(path)], check=True, capture_output=True)


def main():
    microphone = "--microphone" in sys.argv
    player = WORK / "AppleCam Tone Player.app"
    harness = WORK / "WindowSoundHarness.app"
    for app in (player, harness):
        subprocess.run(["rm", "-rf", str(app)], check=True)

    def add_helper(path):
        helper = path / "Contents/Helpers/Tone Helper.app"
        bundle(helper, "com.vanguardsignals.AppleCam.TonePlayer.helper", "Tone Helper", "TonePlayer", [ROOT / "Tests/Integration/TonePlayer.swift"])

    bundle(player, "com.vanguardsignals.AppleCam.TonePlayer", "AppleCam Tone Player", "TonePlayer", [ROOT / "Tests/Integration/TonePlayer.swift"], helper=add_helper)
    sources = [*sorted((ROOT / "Shared").glob("*.swift")), *sorted((ROOT / "AppleCam/Audio").glob("*.swift")), *sorted((ROOT / "AppleCam/Recording").glob("*.swift")),
               ROOT / "AppleCam/Scenes/SceneMediaSource.swift", ROOT / "AppleCam/Scenes/BrowserSceneSource.swift", ROOT / "AppleCam/Scenes/CaptureSelection.swift",
               ROOT / "AppleCam/Processing/GreenScreenProcessor.swift", ROOT / "Tests/Integration/WindowSoundHarness.swift"]
    bundle(harness, "com.vanguardsignals.AppleCam.WindowSoundHarness", "AppleCam Window Sound Verification", "WindowSoundHarness", sources,
           extra={"NSAudioCaptureUsageDescription": "Verifies that AppleCam captures a window's app sound and keeps it off the speakers."})
    meter = None
    with tempfile.TemporaryDirectory(prefix="applecam-window-sound-") as temporary:
        directory = Path(temporary)
        if microphone:
            subprocess.run(["swiftc", str(ROOT / "Tests/Integration/microphone-level.swift"), "-o", str(directory / "meter")], check=True)
            meter = subprocess.Popen([str(directory / "meter"), "90", "880", "1320"], stdout=open(directory / "mic.log", "w"))
            time.sleep(1)
        subprocess.run(["open", "-n", str(player), "--args", "--helper-after", "12"], check=True)
        pid = None
        for _ in range(50):
            found = subprocess.run(["pgrep", "-f", f"{player}/Contents/MacOS/TonePlayer"], capture_output=True, text=True).stdout.split()
            if found:
                pid = found[0]; break
            time.sleep(0.1)
        if pid is None:
            raise SystemExit("The tone player did not start.")
        log = directory / "harness.log"
        try:
            time.sleep(1)
            subprocess.run(["open", "-W", "-n", "--stdout", str(log), "--stderr", str(log), str(harness), "--args", pid, "com.vanguardsignals.AppleCam.TonePlayer"], check=True)
        finally:
            subprocess.run(["pkill", "-f", f"{player}/Contents"], check=False)
            if meter:
                meter.terminate(); meter.wait()
        output = log.read_text()
        print(output, end="")
        if microphone:
            phases = [(line.split()[1], float(line.split()[2])) for line in output.splitlines() if line.startswith("PHASE ")]
            readings = [tuple(map(float, line.split())) for line in (directory / "mic.log").read_text().splitlines() if line.strip()]
            for (name, start), (_, end) in zip(phases, phases[1:]):
                inside = [r for r in readings if start + 0.5 <= r[0] <= end]
                if inside:
                    print(f"Microphone during {name}: 880 Hz {statistics.median(r[1] for r in inside):.1f} dB, 1320 Hz {statistics.median(r[2] for r in inside):.1f} dB")
        if "Window sound capture (app, later helper, muted while tapped) passed." not in output:
            raise SystemExit("Window sound integration failed.")


main()

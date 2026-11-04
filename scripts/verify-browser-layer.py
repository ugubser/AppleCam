#!/usr/bin/env python3
"""Opt-in capture of an app-owned WebKit window containing generated local video."""
import functools
import http.server
import math
import plistlib
import secrets
import struct
from pathlib import Path
import subprocess
import tempfile
import threading
import wave

ROOT = Path(__file__).resolve().parent.parent


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_args):
        pass


def tone(path, frequency, amplitude):
    """Twenty seconds of a sine tone: longer than the check, because WebKit needs a moment to restart a looping file."""
    cycle = b"".join(struct.pack("<h", int(amplitude * 32767 * math.sin(2 * math.pi * frequency * i / 48000))) for i in range(4800))
    with wave.open(str(path), "wb") as out:
        out.setnchannels(1); out.setsampwidth(2); out.setframerate(48000)
        out.writeframes(cycle * 200)


with tempfile.TemporaryDirectory(prefix="applecam-browser-") as temporary:
    directory = Path(temporary)
    subprocess.run(["swift", str(ROOT / "Tests/Integration/generate-scene-video.swift"), str(directory / "fixture.mov")], check=True, cwd=ROOT)
    (directory / "index.html").write_text("""<!doctype html><meta charset=utf-8>
<style>html,body{margin:0;background:#000;width:100%;height:100%;overflow:hidden}video{width:100vw;height:100vh;object-fit:fill}</style>
<video src="fixture.mov" autoplay muted loop playsinline></video>""")
    for name, frequency, amplitude in [("near.wav", 440, 0.5), ("frame.wav", 660, 0.25), ("far.wav", 880, 0.5)]:
        tone(directory / name, frequency, amplitude)
    (directory / "frame.html").write_text("""<!doctype html><audio id=tone src="frame.wav" loop autoplay></audio>""")
    handler = functools.partial(QuietHandler, directory=temporary)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    # Page sound: a tone in the page, one in a same-site frame (a second stream) and one from another origin
    # (localhost instead of 127.0.0.1), which Web Audio may only receive as silence.
    (directory / "sound.html").write_text(f"""<!doctype html><meta charset=utf-8>
<style>html,body{{margin:0;background:#000;width:100%;height:100%;overflow:hidden}}video{{width:100vw;height:100vh;object-fit:fill}}iframe{{position:absolute;width:10px;height:10px;border:0}}</style>
<video src="fixture.mov" autoplay muted loop playsinline></video>
<audio id=near src="near.wav" loop autoplay></audio>
<audio id=far src="http://localhost:{server.server_port}/far.wav" loop autoplay></audio>
<iframe src="frame.html"></iframe>""")
    app = ROOT / "work/BrowserLayerHarness.app"
    executable = app / "Contents/MacOS/BrowserLayerHarness"
    executable.parent.mkdir(parents=True, exist_ok=True)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.vanguardsignals.AppleCam.BrowserLayerHarness", "CFBundleExecutable": executable.name, "CFBundlePackageType": "APPL", "CFBundleName": "AppleCam Browser Verification", "LSMinimumSystemVersion": "15.2"}))
    sources = [*sorted((ROOT / "Shared").glob("*.swift")), ROOT / "AppleCam/Processing/GreenScreenProcessor.swift", ROOT / "AppleCam/Scenes/SceneMediaSource.swift", ROOT / "AppleCam/Scenes/BrowserSceneSource.swift", ROOT / "AppleCam/Scenes/CaptureSelection.swift",
               *sorted((ROOT / "AppleCam/Audio").glob("*.swift")), *sorted((ROOT / "AppleCam/Recording").glob("*.swift")), ROOT / "Tests/Integration/BrowserLayerHarness.swift"]
    subprocess.run(["swiftc", "-parse-as-library", "-target", "arm64-apple-macos15.2", *map(str, sources), "-o", str(executable)], cwd=ROOT, check=True)
    address = f"http://127.0.0.1:{server.server_port}/index.html"
    sound = f"http://127.0.0.1:{server.server_port}/sound.html"
    token = secrets.token_hex(8)
    try:
        # Two launches: the first stores a session, the second checks it was kept, then runs the other checks.
        subprocess.run([str(executable), "--write-session", address, token], cwd=ROOT, check=True)
        subprocess.run([str(executable), address, sound, token], cwd=ROOT, check=True)
    finally:
        server.shutdown(); server.server_close(); thread.join()

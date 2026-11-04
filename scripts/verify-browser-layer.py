#!/usr/bin/env python3
"""Opt-in capture of an app-owned WebKit window containing generated local video."""
import functools
import http.server
import plistlib
from pathlib import Path
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parent.parent


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_args):
        pass


with tempfile.TemporaryDirectory(prefix="applecam-browser-") as temporary:
    directory = Path(temporary)
    subprocess.run(["swift", str(ROOT / "Tests/Integration/generate-scene-video.swift"), str(directory / "fixture.mov")], check=True, cwd=ROOT)
    (directory / "index.html").write_text("""<!doctype html><meta charset=utf-8>
<style>html,body{margin:0;background:#000;width:100%;height:100%;overflow:hidden}video{width:100vw;height:100vh;object-fit:fill}</style>
<video src="fixture.mov" autoplay muted loop playsinline></video>""")
    handler = functools.partial(QuietHandler, directory=temporary)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    app = ROOT / "work/BrowserLayerHarness.app"
    executable = app / "Contents/MacOS/BrowserLayerHarness"
    executable.parent.mkdir(parents=True, exist_ok=True)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.vanguardsignals.AppleCam.BrowserLayerHarness", "CFBundleExecutable": executable.name, "CFBundlePackageType": "APPL", "CFBundleName": "AppleCam Browser Verification", "LSMinimumSystemVersion": "15.2"}))
    sources = [*sorted((ROOT / "Shared").glob("*.swift")), ROOT / "AppleCam/Processing/GreenScreenProcessor.swift", ROOT / "AppleCam/Scenes/SceneMediaSource.swift", ROOT / "AppleCam/Scenes/BrowserSceneSource.swift", ROOT / "AppleCam/Scenes/CaptureSelection.swift",
               *sorted((ROOT / "AppleCam/Audio").glob("*.swift")), *sorted((ROOT / "AppleCam/Recording").glob("*.swift")), ROOT / "Tests/Integration/BrowserLayerHarness.swift"]
    subprocess.run(["swiftc", "-parse-as-library", "-target", "arm64-apple-macos15.2", *map(str, sources), "-o", str(executable)], cwd=ROOT, check=True)
    address = f"http://127.0.0.1:{server.server_port}/index.html"
    try:
        subprocess.run([str(executable), address], cwd=ROOT, check=True)
    finally:
        server.shutdown(); server.server_close(); thread.join()

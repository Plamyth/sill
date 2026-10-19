#!/usr/bin/env python3
"""Compile extracted production capture lifecycle with inert SCStream. Usage: run.py ROOT OUTPUT."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

if len(sys.argv) != 3:
    raise SystemExit("usage: run.py ROOT OUTPUT")
root, output = [Path(value).resolve() for value in sys.argv[1:]]
if output == root or root in output.parents or not output.is_dir() or any(output.iterdir()):
    raise SystemExit("OUTPUT must be an existing empty parent-owned directory outside ROOT")
source_path = root / "Sources/SillHost/SystemAudioCapture.swift"
source = source_path.read_text()

def block(text, marker):
    start = text.index(marker)
    end = text.index("{", start) + 1
    depth = 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]

capture = block(source, "final class SystemAudioCapture:")
sample = block(capture, "    func stream(_ stream: SCStream, didOutputSampleBuffer")
assert capture.count(sample) == 1
capture = capture.replace(sample, "")
fixture_path = root / "Tests/checks/system-audio-retirement/Fixture.swift"
fixture = fixture_path.read_text()
assert fixture.count("// PRODUCTION_CAPTURE") == 1
emitted = fixture.replace("// PRODUCTION_CAPTURE", capture)
(output / "Checks.swift").write_text(emitted)
for name in ["tmp", "module-cache", "clang-cache"]:
    (output / name).mkdir()
env = dict(os.environ, TMPDIR=str(output / "tmp"),
           SWIFTPM_MODULECACHE_OVERRIDE=str(output / "module-cache"),
           CLANG_MODULE_CACHE_PATH=str(output / "clang-cache"))
record = {"productionSHA256": hashlib.sha256(source.encode()).hexdigest(),
          "fixtureSHA256": hashlib.sha256(fixture.encode()).hexdigest(),
          "extractedSHA256": hashlib.sha256(capture.encode()).hexdigest(),
          "scope": "Actual start/stop/delegate/barrier methods and fields; fake SCStream; no ScreenCaptureKit, HAL, app, network or device IO",
          "commands": [], "exitCode": 2}
try:
    compiler = os.environ.get("SWIFTC", "/usr/bin/swiftc")
    commands = [[compiler, "-swift-version", "5", "-parse-as-library", "-module-cache-path", str(output / "module-cache"),
                 "-o", str(output / "checks"), str(output / "Checks.swift")], [str(output / "checks")]]
    for index, command in enumerate(commands):
        result = subprocess.run(command, cwd=output, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
        (output / ("compile.log" if index == 0 else "checks.log")).write_bytes(result.stdout)
        sys.stdout.buffer.write(result.stdout)
        record["commands"].append({"command": command, "exitCode": result.returncode})
        record["exitCode"] = result.returncode
        if result.returncode:
            break
    record["sourceUnchanged"] = source_path.read_text() == source and fixture_path.read_text() == fixture
    if not record["sourceUnchanged"]:
        record["exitCode"] = 2
except Exception as error:
    record["error"] = str(error)
    record["exitCode"] = 2
(output / "result.json").write_text(json.dumps(record, indent=2) + "\n")
print("SUITE_RESULT " + json.dumps(record, sort_keys=True), flush=True)
raise SystemExit(record["exitCode"])

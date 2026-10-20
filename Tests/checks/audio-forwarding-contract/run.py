#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

root, out = (Path(value).resolve() for value in sys.argv[1:])
out.mkdir(parents=True, exist_ok=True)
sources = [root / name for name in [
    "Sources/SillHost/LocalAudioParticipants.swift",
    "Sources/SillHost/AudioForwardingContract.swift",
    "Tests/checks/audio-forwarding-contract/Main.swift",
]]
def hashes():
    return {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sources}
before = hashes()
env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
binary = out / "audio-forwarding-contract-checks"
with (out / "compile.log").open("w") as log:
    compiled = subprocess.run(["xcrun", "swiftc", "-parse-as-library", *map(str, sources),
        "-o", str(binary)], env=env, stdout=log, stderr=subprocess.STDOUT, timeout=180)
executed = None
if compiled.returncode == 0:
    with (out / "checks.log").open("w") as log:
        executed = subprocess.run([str(binary)], env=env, stdout=log, stderr=subprocess.STDOUT, timeout=30)
after = hashes()
passed = compiled.returncode == 0 and executed is not None and executed.returncode == 0 and before == after
receipt = {"compileExit": compiled.returncode, "checksExit": executed.returncode if executed else None,
    "sourceHashes": before, "sourceUnchanged": before == after, "passed": passed,
    "actualMediaOrDeviceActions": False}
(out / "result.json").write_text(json.dumps(receipt, indent=2) + "\n")
print(json.dumps(receipt))
sys.exit(0 if passed else 1)

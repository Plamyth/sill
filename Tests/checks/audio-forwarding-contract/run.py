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
protocol = sorted((root / "Sources/StreamProtocol").glob("*.swift"))
inputs = sources + protocol + [Path(__file__).resolve()]
def hashes():
    return {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
before = hashes()
protocol_hashes = {str(path.relative_to(root)): before[str(path.relative_to(root))] for path in protocol}
env = dict(os.environ)
binary = out / "audio-forwarding-contract-checks"
shared = ["xcrun", "swiftc", "-package-name", "Sill", "-module-cache-path", str(out / "cache")]
with (out / "protocol-compile.log").open("w") as log:
    module = subprocess.run(shared + ["-emit-library", "-emit-module", "-module-name", "StreamProtocol",
        *map(str, protocol), "-o", str(out / "libStreamProtocol.dylib"),
        "-emit-module-path", str(out / "StreamProtocol.swiftmodule")],
        env=env, stdout=log, stderr=subprocess.STDOUT, timeout=180)
compiled = None
if module.returncode == 0:
    with (out / "compile.log").open("w") as log:
        compiled = subprocess.run(shared + ["-parse-as-library", "-I", str(out), "-L", str(out),
            "-lStreamProtocol", "-Xlinker", "-rpath", "-Xlinker", str(out), *map(str, sources),
            "-o", str(binary)], env=env, stdout=log, stderr=subprocess.STDOUT, timeout=180)
executed = None
if compiled is not None and compiled.returncode == 0:
    with (out / "checks.log").open("w") as log:
        executed = subprocess.run([str(binary)], env=env, stdout=log, stderr=subprocess.STDOUT, timeout=30)
after = hashes()
passed = compiled is not None and compiled.returncode == 0 and executed is not None and executed.returncode == 0 and before == after
receipt = {"protocolCompileExit": module.returncode, "compileExit": compiled.returncode if compiled else None,
    "checksExit": executed.returncode if executed else None,
    "sourceHashes": before, "sharedModuleSourceHashes": protocol_hashes, "sourceUnchanged": before == after, "passed": passed,
    "actualMediaOrDeviceActions": False}
(out / "result.json").write_text(json.dumps(receipt, indent=2) + "\n")
print(json.dumps(receipt))
sys.exit(0 if passed else 1)

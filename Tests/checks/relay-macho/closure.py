import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parents[3]
package, output = (Path(value).resolve() for value in sys.argv[1:3])
output.mkdir(parents=True, exist_ok=False)
files = [root / "Sources/SillHost" / name for name in ["LocalAudioRelayLaunch.swift", "LocalAudioRelayClosure.swift", "LocalAudioRelayMachO.swift", "LocalAudioRelay.swift", "LocalAudioParticipants.swift", "AudioForwardingContract.swift"]]
files.append(Path(__file__).with_name("ClosureMain.swift"))
original = {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in files}
relay = (root / "Sources/SillHost/RemoteAccess.swift").read_text()
start = relay.index("struct AudioForwardingPairedDevice:")
end = relay.index("\n}", start) + 2
support = output / "PairedDevice.swift"
support.write_text("import Foundation\n" + relay[start:end] + "\n")
record = {"sourceHashes": original, "typeExcerptSHA256": hashlib.sha256(support.read_bytes()).hexdigest(),
          "installed": False, "audioOpened": False, "serverStarted": False, "canonicalSelfSignatureTested": False,
          "cases": [], "exitCode": 2}
try:
    env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
    args = ["/usr/bin/xcrun", "swiftc", "-swift-version", "5", "-module-cache-path", str(output / "cache")]
    result = subprocess.run(args + [str(path) for path in files] + [str(support), "-o", str(output / "check")],
                            capture_output=True, text=True, env=env, timeout=180)
    (output / "compile.log").write_text(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError("closure verifier did not compile")
    def execute(path, expected):
        result = subprocess.run([str(output / "check"), str(path)], capture_output=True, text=True, timeout=120)
        record["cases"].append({"expected": expected, "exitCode": result.returncode, "log": result.stdout + result.stderr})
        if (result.returncode == 0) != expected:
            raise RuntimeError("unexpected closure verification result")
    execute(package, True)
    result = subprocess.run([str(output / "check"), str(package), "factory-rejection"], capture_output=True, text=True, timeout=30)
    record["factoryOutsideCanonicalRefused"] = result.returncode == 0 and "PASS canonical app factory refuses" in result.stdout
    if not record["factoryOutsideCanonicalRefused"]:
        raise RuntimeError("factory allowed non-canonical caller")
    scratch = output / "mutated"
    shutil.copytree(package, scratch)
    manifest = scratch / "manifest.json"
    saved = manifest.read_bytes()
    data = json.loads(saved)
    next(item for item in data["dependencies"] if item["source"] == "node/bin/node")["bundled"] = []
    manifest.write_text(json.dumps(data))
    execute(scratch, False)
    manifest.write_bytes(saved)
    for name in ["server/control-room-server.js", "python/lib/python3.13/site-packages/sounddevice.py", "node/bin/node"]:
        target = scratch / "runtime" / name
        contents = target.read_bytes()
        changed = contents[:12] if name == "node/bin/node" else contents + b"\n# modified\n"
        target.write_bytes(changed)
        data = json.loads(saved)
        entry = next(item for item in data["entries"] if item["path"] == name)
        entry.update(sha256=hashlib.sha256(changed).hexdigest(), size=len(changed))
        manifest.write_text(json.dumps(data))
        execute(scratch, False)
        target.write_bytes(contents)
        manifest.write_bytes(saved)
    record["sourceUnchanged"] = all(hashlib.sha256((root / name).read_bytes()).hexdigest() == value for name, value in original.items())
    assert record["sourceUnchanged"]
    record["exitCode"] = 0
except Exception as error:
    record["error"] = str(error)
finally:
    scratch = output / "mutated"
    if scratch.exists():
        shutil.rmtree(scratch)
    record["scratchRemoved"] = not scratch.exists()
    (output / "result.json").write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n")
print(json.dumps({key: value for key, value in record.items() if key not in ("sourceHashes", "cases")}, ensure_ascii=False))
raise SystemExit(record["exitCode"])

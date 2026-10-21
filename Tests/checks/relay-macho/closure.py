import hashlib
import importlib.util
import io
import json
import marshal
import os
from pathlib import Path
import shutil
import subprocess
import sys
import zipfile

NODE_COMMIT = "24190a6af7306e06b9e681042034f8556c8942fb"

root = Path(__file__).resolve().parents[3]
package, output = (Path(value).resolve() for value in sys.argv[1:3])
output.mkdir(parents=True, exist_ok=False)
files = [root / "Sources/SillHost" / name for name in ["LocalAudioRelayLaunch.swift", "LocalAudioRelayClosure.swift", "LocalAudioRelayMachO.swift", "LocalAudioRelay.swift", "LocalAudioParticipants.swift", "AudioForwardingContract.swift", "AudioForwardingCoordinator.swift"]]
files.append(Path(__file__).with_name("ClosureMain.swift"))
protocol = sorted((root / 'Sources/StreamProtocol').glob('*.swift'))
inputs = files + protocol + [root / 'Sources/SillHost/RemoteAccess.swift', Path(__file__).resolve()]
original = {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
relay = (root / "Sources/SillHost/RemoteAccess.swift").read_text()
start = relay.index("struct AudioForwardingPairedDevice:")
end = relay.index("\n}", start) + 2
support = output / "PairedDevice.swift"
support.write_text("import Foundation\nimport StreamProtocol\n" + relay[start:end] + "\n")
record = {"sourceHashes": original, "typeExcerptSHA256": hashlib.sha256(support.read_bytes()).hexdigest(),
          "sharedModuleSourceHashes": {str(p.relative_to(root)): original[str(p.relative_to(root))] for p in protocol},
          "installed": False, "audioOpened": False, "serverStarted": False, "canonicalSelfSignatureTested": False,
          "cases": [], "exitCode": 2}
try:
    assert json.loads((package / "manifest.json").read_text())["nodeSourceCommit"] == NODE_COMMIT
    env = dict(os.environ)
    args = ["/usr/bin/xcrun", "swiftc", "-swift-version", "5", "-package-name", "Sill", "-module-cache-path", str(output / "cache")]
    module = subprocess.run(args + ['-emit-library', '-emit-module', '-module-name', 'StreamProtocol',
        *map(str, protocol), '-o', str(output / 'libStreamProtocol.dylib'),
        '-emit-module-path', str(output / 'StreamProtocol.swiftmodule')],
        capture_output=True, text=True, env=env, timeout=180)
    (output / 'protocol-compile.log').write_text(module.stdout + module.stderr)
    if module.returncode:
        raise RuntimeError('shared protocol module did not compile')
    result = subprocess.run(args + ['-I', str(output), '-L', str(output), '-lStreamProtocol',
        '-Xlinker', '-rpath', '-Xlinker', str(output)] + [str(path) for path in files] + [str(support), "-o", str(output / "check")],
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
    data["nodeSourceCommit"] = "633beec7207f6c3b5ee2a2eef399eabed36039be"
    manifest.write_text(json.dumps(data))
    execute(scratch, False)
    manifest.write_bytes(saved)
    data = json.loads(saved)
    data["nodeSourceCommit"] = "aa98e05842fccc034c1efd28461b489fe3d1a5b4"
    manifest.write_text(json.dumps(data))
    execute(scratch, False)
    manifest.write_bytes(saved)
    data = json.loads(saved)
    data["nodeSourceCommit"] = "97f640bc6202a451b2211321aa96f20ee1a0f5ef"
    manifest.write_text(json.dumps(data))
    execute(scratch, False)
    manifest.write_bytes(saved)
    data = json.loads(saved)
    data["nodeSourceCommit"] = "1f846e8b776dec9b504cebf78735e57dc1ad5cda"
    manifest.write_text(json.dumps(data))
    execute(scratch, False)
    manifest.write_bytes(saved)
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
    cache = importlib.util.MAGIC_NUMBER + bytes(12) + marshal.dumps(compile("probe = True", "sitecustomize.py", "exec"))
    archive = io.BytesIO()
    with zipfile.ZipFile(archive, "w") as stream:
        stream.writestr("probe.py", "value = 'test'\n")
    for name, contents in [
        ("python/lib/python3.13/sitecustomize.pyc", cache),
        ("python/lib/python3.13/probe.PYO", cache),
        ("python/lib/python3.13/probe.zip", archive.getvalue()),
        ("python/lib/python3.13/probe.egg", archive.getvalue()),
        ("python/lib/python3.13/__pycache__/probe", cache),
    ]:
        target = scratch / "runtime" / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(contents)
        target.chmod(0o644)
        data = json.loads(saved)
        parent = str(Path(name).parent)
        if not any(item["path"] == parent for item in data["entries"]):
            data["entries"].append({"path": parent, "kind": "directory", "mode": 0o755})
        data["entries"].append({"path": name, "kind": "file", "mode": 0o644,
                                "size": len(contents), "sha256": hashlib.sha256(contents).hexdigest()})
        data["dependencies"].append({"source": name, "bundled": [], "system": []})
        manifest.write_text(json.dumps(data))
        execute(scratch, False)
        target.unlink()
        if parent.endswith("/__pycache__"): target.parent.rmdir()
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

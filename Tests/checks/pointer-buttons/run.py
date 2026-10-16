#!/usr/bin/env python3
"""Compile the real injector and the coordinator's input queue without starting a host."""
import hashlib
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
OUT = Path(os.environ.get("SILL_CHECK_OUTPUT", str(ROOT / ".build/checks/pointer-buttons")))
BASE = "d669a813454603f76074491724ecb4339ad2185c"
baseline = sys.argv[1:] == ["--baseline"]
if sys.argv[1:] and not baseline:
    raise SystemExit("usage: run.py [--baseline]")
OUT.mkdir(parents=True, exist_ok=True)


def source(name):
    path = f"Sources/SillHost/{name}.swift"
    if baseline and name in ("InputInjector", "StreamCoordinator"):
        text = subprocess.check_output(["git", "show", f"{BASE}:{path}"], cwd=ROOT, text=True)
        saved = OUT / f"baseline/{name}.swift"
        saved.parent.mkdir(exist_ok=True)
        saved.write_text(text)
        return saved, text
    return ROOT / path, (ROOT / path).read_text()


injector, _ = source("InputInjector")
_, coordinator = source("StreamCoordinator")
release = "releaseKeys" if baseline else "releaseInput"
query = "isUpOfSomethingDown(event)" if baseline else "isUpOfSomethingDown(event, from: device)"
disconnect = coordinator.split("server.onClientDisconnected =", 1)[1].split("server.onClientCountChanged =", 1)[0]
assert f"self.{release}(of: id)" in disconnect, "disconnect must use the tested cleanup"
expected_release_paths = 2 if baseline else 3
assert coordinator.count(f"injector.{query}") == expected_release_paths, "every no-source or epoch rejection must check releases"
queue = coordinator.split("    private enum Held {", 1)[1].split("    private func raiseIfInteracting", 1)[0]
queue = "    private enum Held {" + queue
drop = coordinator.split("        let dropped = heldInput", 1)[1].split("        encoder = nil", 1)[0]
drop = "        let dropped = heldInput" + drop
buffer = f"""import Foundation
import StreamProtocol

@MainActor
final class BufferedInput {{
    let injector: InputInjector
    var switching = false
    func presentationInputRect(_ input: SourceInput?) -> CGRect? {{ nil }}
    init(_ injector: InputInjector) {{ precondition(injector.dryRun); self.injector = injector }}
    func hold() {{ holdUntil = CFAbsoluteTimeGetCurrent() + 60 }}
    func send(_ event: InputEvent, in rect: CGRect, from device: KeyStrokes.Device) {{
        deliver(event, in: rect, from: device)
    }}
    func disconnect(_ device: KeyStrokes.Device) {{ {release}(of: device) }}
    func flush() {{ releaseHeldInput() }}
    func beginSwitch() {{ switching = true }}
    func endSwitch() {{ switching = false }}
    func drop() {{
{drop}
    }}
    private func logClick(_ event: InputEvent, in rect: CGRect) {{}}
{queue}
}}
"""
(OUT / "BufferedInput.swift").write_text(buffer)
host = [source(name)[0] for name in ("KeyStrokes", "GestureChords", "Stats", "PointerControl", "PointerWatch")]
inputs = [injector, *host, HERE / "main.swift", *sorted((ROOT / "Sources/StreamProtocol").glob("*.swift"))]
before = {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
before[ROOT / "Sources/SillHost/StreamCoordinator.swift"] = hashlib.sha256(
    (ROOT / "Sources/SillHost/StreamCoordinator.swift").read_bytes()).hexdigest()


def run(args):
    subprocess.run([str(x) for x in args], cwd=ROOT, check=True, timeout=120)


run(["swiftc", "-emit-module", "-emit-library", "-module-name", "StreamProtocol", "-package-name", "sill",
     *sorted((ROOT / "Sources/StreamProtocol").glob("*.swift")), "-o", OUT / "libStreamProtocol.dylib",
     "-emit-module-path", OUT / "StreamProtocol.swiftmodule"])
run(["swiftc", "-parse-as-library", "-package-name", "sill", "-I", OUT, "-L", OUT, "-lStreamProtocol",
     "-Xlinker", "-rpath", "-Xlinker", OUT, *(["-D", "SILL_BASELINE"] if baseline else []),
     injector, *host, OUT / "BufferedInput.swift", HERE / "main.swift", "-o", OUT / "check"])
result = subprocess.run([str(OUT / "check")], cwd=ROOT, timeout=30)
for path, digest in before.items():
    assert hashlib.sha256(path.read_bytes()).hexdigest() == digest, f"source changed during check: {path}"
print("Exact input source hashes unchanged; no host process started.", flush=True)
raise SystemExit(result.returncode)

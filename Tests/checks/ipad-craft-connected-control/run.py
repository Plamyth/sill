"""Production Swift inputs, one finite compile/run, no network or device effects."""
from pathlib import Path
import hashlib
import os
import signal
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
PROTOCOL = sorted((ROOT / "Sources/StreamProtocol").glob("*.swift"))
APP = [ROOT / "iOSClient" / name for name in [
    "IPadConfiguredCraftAction.swift", "IPadCraftConnectedControl.swift",
    "IPadDesiredAudio.swift", "IPadAudioForwarding.swift", "IPadProviderCall.swift",
]]
INPUTS = PROTOCOL + APP + [HERE / "main.swift", HERE / "README.md", Path(__file__).resolve(),
    ROOT / "iOSClient/StreamClient+ConfiguredCraftAction.swift", ROOT / "iOSClient/IPadAudioRouteChooser.swift",
    ROOT / "iOSClient/StreamClient+DesiredAudio.swift", ROOT / "iOSClient/StreamClient.swift",
    ROOT / "iOSClient/Sill.xcodeproj/project.pbxproj", ROOT / "docs/configured-craft-action-wire-v1.md"]


def hashes():
    return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in INPUTS}


def run(args, budget, env):
    with subprocess.Popen(list(map(str, args)), cwd=ROOT, env=env, start_new_session=True) as process:
        try:
            code = process.wait(timeout=budget)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            raise
        if code:
            raise subprocess.CalledProcessError(code, args)


before = hashes()
temporary = None
print("PROTOCOL_COMPILE_BUDGET=180; APP_COMPILE_BUDGET=180; RUN_BUDGET=15; NO_NETWORK=true", flush=True)
try:
    with tempfile.TemporaryDirectory(prefix=".ipad-craft-connected-", dir=ROOT) as directory:
        temporary = Path(directory)
        cache = temporary / "cache"
        env = dict(os.environ, TMPDIR=str(temporary), CLANG_MODULE_CACHE_PATH=str(cache), SWIFT_MODULECACHE_PATH=str(cache))
        run(["swiftc", "-module-cache-path", cache, "-emit-library", "-emit-module", "-module-name", "StreamProtocol",
             *PROTOCOL, "-emit-module-path", temporary / "StreamProtocol.swiftmodule", "-o", temporary / "libStreamProtocol.dylib"], 180, env)
        run(["swiftc", "-module-cache-path", cache, "-I", temporary, "-L", temporary, "-lStreamProtocol",
             "-Xlinker", "-rpath", "-Xlinker", temporary, *APP, HERE / "main.swift", "-o", temporary / "checks"], 180, env)
        run([temporary / "checks", temporary], 15, env)
finally:
    unchanged = before == hashes()
    removed = temporary is None or not temporary.exists()
    print(f"INPUT_SOURCES_UNCHANGED={str(unchanged).lower()}; SCRATCH_REMOVED={str(removed).lower()}", flush=True)
    assert unchanged and removed

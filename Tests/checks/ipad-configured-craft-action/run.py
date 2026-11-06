"""실제 Foundation 모델을 한 번 컴파일하고 유한 검사 후 자기 임시 경로만 정리한다."""
from pathlib import Path
import hashlib
import os
import signal
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
MODEL = ROOT / "iOSClient/IPadConfiguredCraftAction.swift"
INPUTS = [MODEL, HERE / "main.swift", Path(__file__).resolve(), HERE / "README.md",
          ROOT / "iOSClient/Sill.xcodeproj/project.pbxproj",
          ROOT / "iOSClient/IPadProviderCall.swift", ROOT / "iOSClient/IPadEnrollmentProtocol.swift"]


def hashes():
    return {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in INPUTS}


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
print("COMPILER_BUDGET_SECONDS=180; MODEL_BUDGET_SECONDS=10; COMPILE_COUNT=1", flush=True)
try:
    with tempfile.TemporaryDirectory(prefix=".ipad-configured-craft-action-", dir=ROOT) as directory:
        temporary = Path(directory)
        cache = temporary / "cache"
        env = dict(os.environ, TMPDIR=str(temporary), CLANG_MODULE_CACHE_PATH=str(cache),
                   SWIFT_MODULECACHE_PATH=str(cache))
        run(["swiftc", "-module-cache-path", cache, MODEL, HERE / "main.swift", "-o", temporary / "checks"], 180, env)
        run([temporary / "checks"], 10, env)
finally:
    unchanged = before == hashes()
    removed = temporary is None or not temporary.exists()
    print(f"INPUT_SOURCES_UNCHANGED={str(unchanged).lower()}; SCRATCH_REMOVED={str(removed).lower()}", flush=True)
    assert unchanged and removed

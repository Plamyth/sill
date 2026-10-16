import os
from pathlib import Path
import subprocess
import tempfile

here = Path(__file__).resolve().parent
root = here.parents[2]
cache = root / "iOSClient/Tests/remote-default/.cache"
cache.mkdir(parents=True, exist_ok=True)
env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(cache))

with tempfile.TemporaryDirectory(prefix="build-", dir=here) as folder:
    out = Path(folder)
    sources = sorted((root / "Sources/StreamProtocol").glob("*.swift"))
    sources += [root / "iOSClient/MacAudioRouteSession.swift", here / "main.swift"]
    for path in sources:
        (out / path.name).write_text(path.read_text().replace("import StreamProtocol\n", ""))
    subprocess.run(["swiftc", "-module-cache-path", str(cache), *map(str, sorted(out.glob("*.swift"))),
                    "-o", str(out / "check")], check=True, timeout=180, env=env)
    subprocess.run([str(out / "check")], check=True, timeout=30)

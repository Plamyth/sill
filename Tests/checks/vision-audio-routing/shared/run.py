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

    network = root / "Tests/checks/vision-input-controls/Network.swift"
    subprocess.run(["swiftc", "-module-cache-path", str(cache), "-parse-as-library",
                    "-emit-module", "-emit-object", "-module-name", "Network", str(network),
                    "-emit-module-path", str(out / "Network.swiftmodule"), "-o", str(out / "Network.o")],
                   check=True, timeout=180, env=env)
    (out / "MacAudioRouteTransport.swift").write_text(
        (root / "iOSClient/MacAudioRouteTransport.swift").read_text()
        .replace("#if os(iOS)\n", "").replace("#endif\n", "").replace("import StreamProtocol\n", ""))
    (out / "SessionLink.swift").write_text((root / "iOSClient/SessionLink.swift").read_text())
    (out / "main.swift").write_text((here / "transport.swift").read_text())
    transport_sources = [out / name for name in ["AudioRouting.swift", "StreamMessage.swift",
                                               "SessionLink.swift", "MacAudioRouteTransport.swift", "main.swift"]]
    subprocess.run(["swiftc", "-module-cache-path", str(cache), "-I", str(out),
                    *map(str, transport_sources),
                    str(out / "Network.o"), "-o", str(out / "transport")], check=True, timeout=180, env=env)
    subprocess.run([str(out / "transport")], check=True, timeout=30)

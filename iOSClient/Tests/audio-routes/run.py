import os
from pathlib import Path
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
CLIENT = HERE.parents[1]
ROOT = CLIENT.parent
CACHE = CLIENT / "Tests/remote-default/.cache"
env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(CACHE))

for suite in ["routes", "microphone", "lease"]:
    with tempfile.TemporaryDirectory(prefix="build-", dir=HERE) as folder:
        out = Path(folder)
        sources = sorted((ROOT / "Sources/StreamProtocol").glob("*.swift"))
        if suite == "routes":
            sources += [CLIENT / "IPadAudioRoutePolicy.swift", CLIENT / "IPadRemoteAudioController.swift", CLIENT / "IPadMicrophonePolicy.swift"]
            adapter = (CLIENT / "StreamClient+AudioRoutes.swift").read_text().replace("#if os(iOS)", "#if true")
            fixture = (HERE / "Standins.swift").read_text().replace("// EXTRACTED_ADAPTER", adapter)
            (out / "Adapter.swift").write_text(fixture.replace("import StreamProtocol\n", ""))
            test = HERE / "main.swift"
        elif suite == "microphone":
            sources += [CLIENT / "IPadMicrophonePolicy.swift"]
            test = ROOT / "Tests/checks/ipad-microphone-control/main.swift"
        else:
            sources = [CLIENT / "IPadAudioLeaseState.swift"]
            test = ROOT / "Tests/checks/ipad-audio-lease/main.swift"
        for path in sources + [test]:
            (out / path.name).write_text(path.read_text().replace("import StreamProtocol\n", ""))
        subprocess.run(["swiftc", "-module-cache-path", str(CACHE),
                        *map(str, sorted(out.glob("*.swift"))), "-o", str(out / "check")],
                       check=True, timeout=180, env=env)
        print(f"SUITE {suite}", flush=True)
        subprocess.run([str(out / "check")], check=True, timeout=30)

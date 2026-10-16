import os
from pathlib import Path
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
CLIENT = HERE.parents[1]


def block(text, marker):
    start = text.index(marker)
    opening = text.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]


source = (CLIENT / "StreamClient.swift").read_text()
markers = [
    "private enum StartupAutoConnection",
    "func armSavedMacAutoConnect()",
    "private func trySavedMacAutoConnect()",
    "private func dialUnconstrained(",
]
if "func fallBackFromStartupWired()" in source:
    markers.append("func fallBackFromStartupWired()")
methods = "\n".join(block(source, marker) for marker in markers).replace("#if os(iOS)", "#if true")
fixture = (HERE / "Standins.swift").read_text().replace("// EXTRACTED_METHODS", methods)
remote = (CLIENT / "StreamClient+Remote.swift").read_text()
start = remote.index("        if homeSessionEnded(s, error: error, goodbye: goodbye?.reason) { return }")
end = remote.index("        // The automatic reconnect's own dial", start)
fixture = fixture.replace("// EXTRACTED_SESSION_END", remote[start:end].replace("#if os(iOS)", "#if true"))
fixture += (HERE / "scenarios.swift").read_text()
with tempfile.TemporaryDirectory(prefix="build-", dir=HERE) as folder:
    output = Path(folder)
    (output / "main.swift").write_text(fixture)
    cache = HERE / ".cache"
    env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(cache))
    subprocess.run([
        "swiftc", "-module-cache-path", str(cache),
        str(CLIENT / "DiscoveryPolicy.swift"), str(output / "main.swift"),
        "-o", str(output / "check"),
    ], check=True, env=env, timeout=180)
    result = subprocess.run([str(output / "check")], timeout=20)
    raise SystemExit(result.returncode)

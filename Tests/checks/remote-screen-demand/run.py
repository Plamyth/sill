from pathlib import Path
import hashlib
import json
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
here = Path(__file__).resolve().parent
names = ["RemoteScreenDemand.swift", "RemoteScreenDemandPublisher.swift", "ProviderCallSocket.swift",
         "ProviderCallBridge.swift", "LocalAudioRelay.swift"]
sources = [root / "Sources/SillHost" / name for name in names]
before = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}

def section(path, start, end):
    text = path.read_text()
    return text[text.index(start):text.index(end)]

with tempfile.TemporaryDirectory(prefix="scratch-", dir=here) as directory:
    out = Path(directory)
    support = out / "Support.swift"
    support.write_text("import Foundation\n" +
        section(sources[3], "private struct ProviderKey:", "func providerSameSnapshot(") +
        "enum ProviderCallFailure: Error { case invalidFields, invalidIdentity, unavailable, expired, superseded }\n" +
        section(sources[4], "enum LocalAudioRelayJSON {", "@MainActor\nfinal class LocalAudioRelay") +
        "enum ProviderPeerAnchor { enum Policy { case core }; static func verify(_ fd: Int32, policy: Policy) throws -> Bool { true } }\n")
    socket = sources[2].read_text()
    framing = out / "Framing.swift"
    framing.write_text("import Foundation\nimport Darwin\nenum ProductionFraming {\n"
        "static let limit = 32_768\n" +
        socket[socket.index("    private static func wait("):socket.index("    private static func endpoint(")]
            .replace("private static func", "static func") + "}\n")
    binary = out / "checks"
    command = ["xcrun", "swiftc", "-swift-version", "5", "-warnings-as-errors", "-parse-as-library",
               "-module-cache-path", str(out / "cache"), *map(str, sources[:3]), str(support),
               str(framing), str(here / "Checks.swift"), "-o", str(binary)]
    subprocess.run(command, check=True, timeout=120)
    with tempfile.TemporaryDirectory(prefix=".ccr-sd-", dir=Path.home()) as sockets:
        subprocess.run([str(binary), sockets], check=True, timeout=45)
assert before == {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
print("SOURCE_RESULT=" + json.dumps(dict(sourceHashes=before, sourceUnchanged=True,
    scratchRemoved=not out.exists(), productionSocketCompiled=True, peerAnchor="inert fixture",
    installedHostDeviceUIAudioEffects=0, fullGitSourceGuardAccepted=False), sort_keys=True))

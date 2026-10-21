import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[3]
output = Path(sys.argv[1]).resolve() if len(sys.argv) == 2 else Path(tempfile.mkdtemp(prefix="ccr-auth-role-"))
if len(sys.argv) == 2: output.mkdir(parents=True, exist_ok=False)

def block(text, marker):
    assert text.count(marker) == 1, marker
    start = text.index(marker)
    body = start
    if "func " in marker:
        body = text.index("(", start) + 1
        parameters = 1
        while parameters:
            parameters += (text[body] == "(") - (text[body] == ")"); body += 1
    opening = text.index("{", body); end = opening + 1; depth = 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}"); end += 1
    return text[start:end]

server = (root / "Sources/SillHost/StreamServer.swift").read_text()
fixture = Path(__file__).with_name("Main.swift").read_text()
methods = [block(server, marker) for marker in ["private func register(", "func serve(", "private func took(", "private func unregister(", "func sendAuthenticationCatalog(", "func sendMicrophone(", "private func receiveForwarding(", "func sendForwardingState("]]
fixture = fixture.replace("    // EXCHANGE", block(server, "final class ForwardingExchange:"))
client = block(server, "private final class Client {")
fixture = fixture.replace("    // CLIENT_METHODS", "\n".join(block(client, marker) for marker in ["func invalidateAuthorization(", "func cancel("]))
fixture = fixture.replace("// JSON_VALIDATOR", block((root / 'Sources/SillHost/LocalAudioRelay.swift').read_text(), 'enum LocalAudioRelayJSON {'))
raw = block(server, "private func send(_ raw:")
prefix = raw[raw.index("{") + 1:raw.index("        guard let data = PresentationMedia.adapt")]
prefix = prefix.replace("else { return }", "else { return false }")
prefix = prefix.replace("client.cancel(); return }", "client.cancel(); return false }")
methods.append("func admitsRaw(_ raw: Data, to client: Client) -> Bool {" + prefix + "\nreturn true\n}")
fixture = fixture.replace("    // METHODS", "\n".join(methods).replace("private func", "func"))
fixture = fixture.replace("    // VIEWER_COUNT", block(server, "private var viewerCount:").replace("private var", "var"))
reader = block(server, "private func receiveLoop(")
assert reader.index("guard client.role.accepts(header.kind)") < reader.index("self.onMicrophoneMessage?") < reader.index("self.pointerWatch?.inputArrived")
assert "viewerCount > 0" in block(server, "private func updateTicking(")
assert "client.role.isViewer && client.catalogSent" in block(server, "func broadcast(_ message:")
assert "client.role.isViewer" in block(server, "func sendMicrophoneCatalog(")
assert "client.role.isViewer" in block(server, "func setRemoteAudio(")
original = {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in
            [root / "Sources/SillHost/StreamServer.swift", root / "Sources/SillHost/StreamPeerRole.swift", Path(__file__), Path(__file__).with_name("Main.swift")]}
passed = False
try:
    source = output / "Fixture.swift"; source.write_text(fixture)
    base = ["/usr/bin/xcrun", "swiftc", "-swift-version", "5", "-module-cache-path", str(output / "cache")]
    protocol = base + ["-parse-as-library", "-whole-module-optimization", "-emit-module", "-emit-object", "-module-name", "StreamProtocol"]
    subprocess.run(protocol + [str(p) for p in sorted((root / "Sources/StreamProtocol").glob("*.swift"))] + ["-emit-module-path", str(output / "StreamProtocol.swiftmodule"), "-o", str(output / "StreamProtocol.o")], check=True, timeout=180)
    subprocess.run(base + ["-I", str(output), str(root / "Sources/SillHost/StreamPeerRole.swift"), str(source), str(output / "StreamProtocol.o"), "-o", str(output / "check")], check=True, timeout=180)
    subprocess.run([str(output / "check")], check=True, timeout=30)
    assert all(hashlib.sha256((root / name).read_bytes()).hexdigest() == value for name, value in original.items())
    passed = True
finally:
    import shutil
    shutil.rmtree(output)
    receipt = {"passed": passed, "sourceHashes": original, "outputRemoved": not output.exists(), "hardwareOrDeviceActions": 0}
    if len(sys.argv) == 2: output.with_suffix(".json").write_text(json.dumps(receipt, indent=2) + "\n")
    print("RECEIPT " + json.dumps(receipt))

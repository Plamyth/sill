#!/usr/bin/env python3
"""Execute the production OFF branch with fake route, server and capture.

The source slice is copied verbatim from StreamCoordinator, so deleting its
stop call must make the compiled behavioral witness fail.
"""

import pathlib
import subprocess
import sys


source = pathlib.Path(sys.argv[1]).read_text()
out = pathlib.Path(sys.argv[2])
control = source.split("private func controlRemoteAudio", 1)[1].split("private func sendCatalog", 1)[0]
body = control.split("let id = ObjectIdentifier(connection)", 1)[1]
body = "let id = ObjectIdentifier(connection)" + body.split("guard canEnableRemoteAudio", 1)[0]
stop_call = "stopRemoteAudioIfIdle()"
assert body.count(stop_call) == 1, "OFF stop call missing or ambiguous"


def swift_fixture(off_body: str) -> str:
    return """import Foundation

final class FakeConnection {}
struct Request { let enabled: Bool; let requestID: UUID }
final class FakeServer {
    var disabled = 0
    func setRemoteAudio(_ enabled: Bool, for connection: FakeConnection) {
        if !enabled { disabled += 1 }
    }
}
@MainActor final class Harness {
    var routes: [ObjectIdentifier: Bool] = [:]
    var remoteAudioSubscribers: Set<ObjectIdentifier> = []
    var remoteAudioRequests: [ObjectIdentifier: UUID] = [:]
    var remoteAudioActions: [ObjectIdentifier: UInt64] = [:]
    var nextRemoteAudioAction: UInt64 = 0
    var server = FakeServer()
    var captureActive = true
    var stopCalls = 0
    var ack: UUID?

    func remoteAudioState(_ enabled: Bool, requestID: UUID, to connection: FakeConnection) {
        if !enabled { ack = requestID }
    }
    func stopRemoteAudioIfIdle() {
        guard remoteAudioSubscribers.isEmpty else { return }
        stopCalls += 1
        captureActive = false
    }
    func controlRemoteAudio(_ request: Request, from connection: FakeConnection) async {
""" + off_body + """
    }
}
@main struct Check {
    @MainActor static func main() async {
        let h = Harness()
        let c = FakeConnection()
        let id = ObjectIdentifier(c)
        h.routes[id] = true
        h.remoteAudioSubscribers.insert(id)
        let request = Request(enabled: false, requestID: UUID())
        await h.controlRemoteAudio(request, from: c)
        precondition(h.remoteAudioSubscribers.isEmpty, "OFF kept a subscriber")
        precondition(h.server.disabled == 1 && h.ack == request.requestID, "OFF missed disabled ACK")
        precondition(h.stopCalls == 1 && !h.captureActive, "last OFF left capture active")
        print("production OFF body: disabled ACK and capture stop passed")
    }
}
"""


def run(name: str, text: str, expected: int) -> None:
    path = out / f"{name}.swift"
    executable = out / name
    path.write_text(swift_fixture(text))
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(path), "-o", str(executable)], check=True)
    result = subprocess.run([str(executable)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if (result.returncode == 0) != (expected == 0):
        raise AssertionError(f"{name}: unexpected exit {result.returncode}: {result.stderr.decode()[:600]}")
    if expected == 0:
        print(result.stdout.decode().strip())


run("off-baseline", body, 0)
run("off-delete-stop", body.replace(stop_call, "/* deleted stop */"), 1)
print("production OFF deletion mutant: caught")

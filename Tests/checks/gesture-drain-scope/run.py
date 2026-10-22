#!/usr/bin/env python3
"""생산 제스처 수신·큐·held 재생을 추출한다. 기본 실행 경로는 없다."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
BASE = "068be8f4a50444716aefe86347e7ae5dfa947f5d"
HOST = "Sources/SillHost/StreamCoordinator.swift"


def block(source, marker):
    start = source.index(marker)
    end = source.index("{", start) + 1
    depth = 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def generate(ref):
    if ref:
        ref = subprocess.check_output(
            ["git", "--no-lazy-fetch", "rev-parse", "--verify", ref + "^{commit}"], cwd=ROOT, text=True
        ).strip()
    manifest = {}

    def read(path):
        text = subprocess.check_output(
            ["git", "--no-lazy-fetch", "show", ref + ":" + path], cwd=ROOT, text=True
        ) if ref else (ROOT / path).read_text()
        manifest[path] = hashlib.sha256(text.encode()).hexdigest()
        return text

    host = read(HOST)
    switcher = read("Sources/StreamProtocol/Switcher.swift")
    protocol = read("Sources/StreamProtocol/Input.swift")
    gesture = read("Sources/StreamProtocol/Gesture.swift")
    fence = read("Sources/SillHost/SourceInputFence.swift").replace("import StreamProtocol", "")
    chords = read("Sources/SillHost/GestureChords.swift")
    inventory = read("Sources/SillHost/DisplayInventory.swift").replace("import StreamProtocol", "")
    wire = "enum Wire {\n" + "\n".join(block(switcher, x) for x in [
        "public static func encode<T:", "public static func decode<T:"]) + "\n}"
    types = "\n".join(block(switcher, x) for x in [
        "public enum StreamSource:", *(["public struct SourceRequest:"] if "public struct SourceRequest:" in switcher else []), "public struct DisplayInfo:",
        "public struct DisplaySelection:", "public struct VideoEpoch:"])
    shared = "\n".join(["import Foundation\nimport CoreFoundation\nimport CoreGraphics", types, protocol,
                         gesture, wire, fence, chords, inventory])
    members = host[host.index("    private var gestureChords ="):host.index("    /// A host that does not advertise")]
    members = members.replace("private ", "")
    properties = []
    if "struct SourcePick {" in host:
        properties += [block(host, marker).replace("private ", "") for marker in ["struct SourcePick {", "private struct PendingLaunch"]]
        properties += ["var launchID = \"gesture-host\"", "var selectionRevision: String { \"\\(launchID):\\(pickSequence)\" }"]
        for marker in ["private var pickSequence:", "private var settledPickSequence:", "private var sourcePublicationAdmission =", "private var sourceAdmissionPick:", "private var pendingLaunch:"]:
            properties.append(host[host.index(marker):].splitlines()[0].replace("private ", ""))
        shared += "\n" + block(read("Sources/SillHost/StreamServer.swift"), "final class SourcePublicationAdmission")

    for marker in ["private var inputGeneration =", "private var videoEpoch:",
                   "package private(set) var active:", "private var switching =",
                   "private var restartOf:", "private var pickArrivedWhileSwitching:"]:
        line = host[host.index(marker):].splitlines()[0]
        declaration = block(host, marker) if "{" in line else line
        properties.append(declaration.replace("package private(set) ", "").replace("private ", ""))
    token = "private var gestureScopeToken ="
    if token in host:
        line = host[host.index(token):].splitlines()[0]
        declaration = block(host, token) if "{" in line else line
        properties.append(declaration.replace("private ", ""))
    methods = ["queueGesture(", "performGesture(", "releaseHeldInput()", "releaseInput(of",
               "deliver(_", "applyAdmittedInput(_", "applyAdmittedChord("]
    methods += [x for x in ["gestureContext(", "gestureIsCurrent(", "applyAdmittedGesture(",
                "handleSourceSelection(", "handlePick(", "gestureSelectionIsLive(", "bindGestureSelection(",
                "changingGestureScope(", "currentGestureDesktop(", "commitGestureSelection(",
                "finishGestureSelection(", "gestureDesktopIsCurrent(", "gestureIsWaiting("]
                if "private func " + x in host]
    methods += [x for x in ["sourcePeerIsLive(", "automaticSelectionIsAllowed(", "reserveSourceIntent(", "admissionIsCurrent(", "rejectSourceIntent("] if "private func " + x in host]
    extracted = "\n".join(block(host, "private func " + x) for x in methods)
    ticketed = "private func selectStream(" in host
    selection = block(host, "private func selectStream(" if ticketed else "func select(_ source:")
    entry = selection[:selection.index("        defer {")]
    finish = selection[selection.index("            switching = false"):selection.index("            for connection in connections.values")]
    queued = selection[selection.index("            var pick ="):selection.index("            // Requests that arrived mid-switch")]
    queued += "\n" + next(line for line in selection.splitlines() if "if catalog.clientCount == 0 { pick = nil }" in line)
    queued += "\n" + block(selection, "            if let pick, admissionIsCurrent(pick) {" if "intent: SourcePick" in selection else "            if let pick, pick != active {")
    preflight = selection[selection.index("        if source == .desktop, !synthetic"):selection.index("        server.resetForNewStream()")]
    call = "await selectionPipeline(source: source" + (", gestureOperation: gestureOperation" if ticketed else "") + ")"
    selector = entry + "        defer {\n" + finish + "            restartOf = nil\n" + queued + "\n        }\n" + preflight + call + "\n}"
    if ticketed:
        selector = block(host, "func select(_ source:") + "\n" + selector
    pipeline = block(host, "private func startPipeline(")
    commit_start = pipeline.index("        changingGestureScope(for: gestureOperation) {") if ticketed else pipeline.index("        active = source")
    commit = pipeline[commit_start:pipeline.index("        server.commitVideo(")]
    selector += "\n" + """func selectionPipeline(source: StreamSource, gestureOperation: UUID? = nil) async {
        await beforePipelineCommit?()
        guard !failPipeline else { return }
        let generation = source == active ? inputGeneration : UUID().uuidString
        let epoch = VideoEpoch(generation: generation, source: source,
            geometry: .init(x: 0, y: 0, width: 100, height: 100), width: 100, height: 100)
""" + commit + "\n        await afterPipelineCommit?()\n}"
    display_change = block(host, "private func displaysChanged()")
    display_change = display_change[:display_change.index("        guard !synthetic")] + "\n}"
    held = block(host, "private enum Held")
    receive = host[host.index("        case .gesture:\n"):host.index("        case .remoteAudioControl:\n", host.index("        case .gesture:\n"))]
    receive += host[host.index("        case .selectDisplay:\n"):host.index("        case .windowCommand:\n")]
    receive = "func receive(_ message: StreamMessage, from connection: NWConnection) async {\nswitch message.kind {\n" + receive + "default: break\n}\n}"
    body = "\n".join(properties + [members, held, extracted, selector, display_change, receive])
    body = body.replace("private ", "").replace("Task<Void, Never>", "InertTask")
    body = body.replace("Task {", "InertTask {").replace("Task.sleep", "InertTask.sleep").replace("Task.isCancelled", "InertTask.isCancelled")
    body = body.replace("StreamCoordinator.", "Harness.")
    fixture = (HERE / "Fixture.swift").read_text().replace("// PRODUCTION_MEMBERS", body)
    checks = (HERE / "Checks.swift").read_text()
    for name in ["run.py", "Fixture.swift", "Checks.swift"]:
        manifest[str((HERE / name).relative_to(ROOT))] = hashlib.sha256((HERE / name).read_bytes()).hexdigest()
    manifest["extractedHost"] = hashlib.sha256(body.encode()).hexdigest()
    print(json.dumps({"ref": ref or "working-tree", "sourceHashes": manifest}, sort_keys=True), file=sys.stderr)
    return shared + "\n" + fixture + "\n" + checks


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    revision = parser.add_mutually_exclusive_group()
    revision.add_argument("--baseline", action="store_true", help="원본 068의 생산 소스를 추출한다")
    revision.add_argument("--ref", help="이 Git ref의 생산 소스를 현재 검사와 비교한다")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--emit-only", action="store_true", help="생성만 한다. Swift를 실행하지 않는다")
    mode.add_argument("--run", action="store_true", help="부모의 Mini 한시 실행 사본 안에서만 사용한다")
    args = parser.parse_args()
    source = generate(BASE if args.baseline else args.ref)
    if args.emit_only:
        sys.stdout.write(source)
        return 0
    with tempfile.TemporaryDirectory(prefix="gesture-drain-scope-") as scratch:
        executable = str(Path(scratch) / "checks")
        result = subprocess.run(["swiftc", "-parse-as-library", "-package-name", "Sill", "-", "-o", executable], input=source, text=True)
        if result.returncode:
            return result.returncode
        return subprocess.run([executable]).returncode


if __name__ == "__main__":
    raise SystemExit(main())

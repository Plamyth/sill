#!/usr/bin/env python3
"""생산 제스처 수신·큐·held 재생을 추출한다. 기본 실행 경로는 없다."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

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


def generate(baseline):
    manifest = {}

    def read(path):
        text = subprocess.check_output(
            ["git", "--no-lazy-fetch", "show", BASE + ":" + path], cwd=ROOT, text=True
        ) if baseline else (ROOT / path).read_text()
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
        "public enum StreamSource:", "public struct DisplayInfo:",
        "public struct DisplaySelection:", "public struct VideoEpoch:"])
    # InputEvent와 SourceInput도 생산 선언 그대로 사용한다.
    shared = "\n".join(["import Foundation\nimport CoreFoundation", types, protocol,
                         gesture, wire, fence, chords, inventory])
    members = host[host.index("    private var gestureChords ="):host.index("    /// A host that does not advertise")]
    members = members.replace("private ", "")
    properties = []
    for marker in ["private var inputGeneration =", "private var videoEpoch:",
                   "package private(set) var active:", "private var switching ="]:
        line = host[host.index(marker):].splitlines()[0]
        declaration = block(host, marker) if "{" in line else line
        properties.append(declaration.replace("package private(set) ", "").replace("private ", ""))
    token = "private var gestureScopeToken ="
    if token in host:
        properties.append(host[host.index(token):].splitlines()[0].replace("private ", ""))
    methods = ["queueGesture(", "performGesture(", "releaseHeldInput()", "releaseInput(of",
               "deliver(_", "applyAdmittedInput(_", "applyAdmittedChord("]
    methods += [x for x in ["gestureContext(", "gestureIsCurrent(", "applyAdmittedGesture("]
                if "private func " + x in host]
    extracted = "\n".join(block(host, "private func " + x) for x in methods)
    held = block(host, "private enum Held")
    receive = host[host.index("        case .gesture:\n"):host.index("        case .remoteAudioControl:\n", host.index("        case .gesture:\n"))]
    receive = "func receive(_ message: StreamMessage, from connection: NWConnection) async {\nswitch message.kind {\n" + receive + "default: break\n}\n}"
    body = "\n".join(properties + [members, held, extracted, receive])
    # 접근 수준과 실행기만 교체한다. 분기·검증·상태 전이는 수정하지 않는다.
    body = body.replace("private ", "").replace("Task<Void, Never>", "InertTask")
    body = body.replace("Task {", "InertTask {").replace("Task.sleep", "InertTask.sleep").replace("Task.isCancelled", "InertTask.isCancelled")
    fixture = (HERE / "Fixture.swift").read_text().replace("// PRODUCTION_MEMBERS", body)
    checks = (HERE / "Checks.swift").read_text()
    manifest["extractedHost"] = hashlib.sha256(body.encode()).hexdigest()
    print(json.dumps({"baseline": baseline, "sourceHashes": manifest}, sort_keys=True), file=sys.stderr)
    return shared + "\n" + fixture + "\n" + checks


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", action="store_true", help="원본 068의 생산 소스를 추출한다")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--emit-only", action="store_true", help="생성만 한다. Swift를 실행하지 않는다")
    mode.add_argument("--run", action="store_true", help="부모의 Mini 한시 실행 사본 안에서만 사용한다")
    args = parser.parse_args()
    source = generate(args.baseline)
    if args.emit_only:
        sys.stdout.write(source)
        return 0
    result = subprocess.run(["swift", "-package-name", "Sill", "-"], input=source, text=True)
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())

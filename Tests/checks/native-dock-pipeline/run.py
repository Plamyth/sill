#!/usr/bin/env python3
"""지정한 생산 소스의 Dock 선택과 실패 복구를 비활성 어댑터로 검사한다."""
import hashlib
import json
import os
from datetime import datetime, timezone
from pathlib import Path
import subprocess
import sys


def extract(source, marker, opening="{", closing="}"):
    if source.count(marker) != 1:
        raise ValueError(f"추출 지점이 유일하지 않습니다: {marker}")
    start = source.index(marker)
    index = source.index(opening, start)
    depth, comment, string = 0, 0, False
    while index < len(source):
        pair = source[index:index + 2]
        char = source[index]
        if comment:
            if pair == "/*":
                comment += 1
                index += 2
                continue
            if pair == "*/":
                comment -= 1
                index += 2
                continue
        elif string:
            if char == "\\":
                index += 2
                continue
            if char == '"':
                string = False
        elif pair == "//":
            index = source.index("\n", index)
            continue
        elif pair == "/*":
            comment = 1
            index += 2
            continue
        elif char == '"':
            string = True
        elif char == opening:
            depth += 1
        elif char == closing:
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
        index += 1
    raise ValueError(f"닫는 괄호가 없습니다: {marker}")


def main():
    root, output = (Path(arg).resolve() for arg in sys.argv[1:])
    route = json.loads(subprocess.check_output([
        "/Users/ambrion/.local/bin/storage-route", "path", "development-archive", "--project", "CCR-Vision"
    ]))
    allowed = Path(route["path"]) / "host-native-dock-20261021" / "pipeline-checks"
    if not output.is_relative_to(allowed):
        raise ValueError(f"허용된 출력 경로가 아닙니다: {output}")
    output.mkdir(parents=True, exist_ok=False)
    for directory in ["tmp", "module-cache"]:
        (output / directory).mkdir(exist_ok=True)
    env = dict(os.environ, TMPDIR=str(output / "tmp"),
               CLANG_MODULE_CACHE_PATH=str(output / "module-cache"),
               SWIFT_MODULECACHE_PATH=str(output / "module-cache"))
    if Path("/Applications/Xcode.app/Contents/Developer").is_dir():
        env["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
    protocol = sorted((root / "Sources/StreamProtocol").glob("*.swift"))
    host = root / "Sources/SillHost/StreamCoordinator.swift"
    ingress = root / "Sources/SillHost/DockSelectionIngress.swift"
    here = Path(__file__).resolve().parent
    inputs = [host, ingress, *protocol]
    hashes = {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
    test_hashes = {name: hashlib.sha256((here / name).read_bytes()).hexdigest() for name in ["fixture.swift", "run.py"]}
    record = {"sourceCommit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
              "sourceTree": subprocess.check_output(["git", "rev-parse", "HEAD^{tree}"], cwd=root, text=True).strip(),
              "sourceSHA256": hashes, "sourceRoot": str(root),
              "sourceWorkingTree": subprocess.check_output(["git", "status", "--porcelain=v1"], cwd=root, text=True),
              "testCommit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=here, text=True).strip(),
              "testTree": subprocess.check_output(["git", "rev-parse", "HEAD^{tree}"], cwd=here, text=True).strip(),
              "testRoot": str(here), "testSHA256": test_hashes,
              "testWorkingTree": subprocess.check_output(["git", "status", "--porcelain=v1"], cwd=here, text=True),
              "output": str(output), "commands": [], "cases": [], "mutations": [],
              "startedAt": datetime.now(timezone.utc).isoformat(),
              "limits": ["실제 OS 캡처, AX, 앱, 기기, 서비스, 오디오와 HAL을 사용하지 않습니다.",
                         "handleDockRequest, select와 startPipeline의 실제 본문을 실행하며 Dock AX 경계는 메모리 객체입니다.",
                         "focusedDockSource의 실제 OS 조회는 실행하지 않습니다.",
                         "독립 검수와 전체 SDK 검사는 부모 담당의 별도 단계입니다."]}

    def run(name, command, timeout=120):
        result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=timeout)
        log = result.stdout + result.stderr
        (output / f"{name}.log").write_text(log)
        record["commands"].append({"name": name, "argv": command, "exitCode": result.returncode})
        return result.returncode, log

    try:
        source = host.read_text()
        markers = ["private enum PipelineEpochError:", "private func startPipeline(",
                   "func select(_ source: StreamSource,", "private static func epochGeometry(",
                   "private func dockPeerIsCurrent(", "private func handleDockRequest(",
                   "private func dockActionIsCurrent("]
        members = {marker: extract(source, marker) for marker in markers}
        admission = extract(source, "@MainActor\nstruct SourceSelectionAdmission {")
        admission_factory = extract(source, "let admission = SourceSelectionAdmission(", "(", ")")
        record["extractedSHA256"] = {key: hashlib.sha256(value.encode()).hexdigest()
                                     for key, value in {**members, "SourceSelectionAdmission": admission,
                                                        "Dock admission factory": admission_factory}.items()}
        template = (here / "fixture.swift").read_text()

        def render(selected_members=members, factory=admission_factory):
            return (template.replace("// ADMISSION_TYPE", admission)
                    .replace("// PRODUCTION_MEMBERS", "\n".join(selected_members.values()))
                    .replace("// ADMISSION_FACTORY", factory))

        fixture = render()
        generated = output / "Fixture.swift"
        generated.write_text(fixture)
        (output / "DockSelectionIngress.swift").write_bytes(ingress.read_bytes())
        swift = ["/usr/bin/xcrun", "swiftc", "-module-cache-path", str(output / "module-cache")]
        version_code, version = run("swift-version", ["/usr/bin/xcrun", "swiftc", "--version"])
        if version_code:
            raise RuntimeError("Swift 버전 확인 실패\n" + version)
        record["swiftVersion"] = version.strip()
        code, log = run("protocol-compile", swift + ["-parse-as-library", "-emit-module", "-emit-object",
            "-whole-module-optimization", "-module-name", "StreamProtocol", *map(str, protocol),
            "-emit-module-path", str(output / "StreamProtocol.swiftmodule"), "-o", str(output / "StreamProtocol.o")])
        if code:
            raise RuntimeError("실제 StreamProtocol 컴파일 실패\n" + log)

        def compile_fixture(name, path):
            return run(name + "-compile", swift + ["-parse-as-library", "-I", str(output),
                str(path), str(output / "DockSelectionIngress.swift"), str(output / "StreamProtocol.o"),
                "-o", str(output / name)])

        code, log = compile_fixture("baseline", generated)
        if code:
            raise RuntimeError("생산 함수와 어댑터 컴파일 실패\n" + log)
        code, log = run("baseline-runtime", [str(output / "baseline")], timeout=30)
        record["cases"] = [json.loads(line.removeprefix("CASE ")) for line in log.splitlines() if line.startswith("CASE ")]
        if not record["cases"]:
            raise RuntimeError("검사 결과가 없습니다\n" + log)
        record["baselineExit"] = code
        record["passed"] = sum(case["passed"] for case in record["cases"])
        record["failed"] = len(record["cases"]) - record["passed"]
        mutants = [
            ("unguarded-commit", "private func startPipeline(", "guard admission.commit(commit) else {", "guard ({ commit(); return true })() else {",
             "capture-start-peer-loss"),
            ("missing-cleanup", "private func startPipeline(", "await capture.stop()\n            await syntheticCapture.stop()", "/* cleanup omitted */",
             "capture-start-new-ticket"),
            ("missing-start-error-cleanup", "private func startPipeline(", "} catch {\n            enc.onEncoded = nil", "} catch {\n            if error is StartFailure { throw error }\n            enc.onEncoded = nil",
             "capture-start-error-cleanup-peer-loss"),
            ("missing-peer-guard", "Dock admission factory", "guard self.dockPeerIsCurrent(connection) else { return false }", "if false { return false }",
             "capture-start-transport-closed"),
        ]
        for name, target, old, new, witness in mutants:
            original = admission_factory if target == "Dock admission factory" else members[target]
            if original.count(old) != 1:
                raise RuntimeError(f"변이 지점이 유일하지 않습니다: {name}")
            path = output / f"{name}.swift"
            changed = original.replace(old, new, 1)
            path.write_text(render(factory=changed) if target == "Dock admission factory"
                            else render(selected_members={**members, target: changed}))
            code, log = compile_fixture(name, path)
            if code:
                raise RuntimeError(f"변이 컴파일 실패: {name}\n{log}")
            code, log = run(name + "-runtime", [str(output / name)], timeout=30)
            cases = [json.loads(line.removeprefix("CASE ")) for line in log.splitlines() if line.startswith("CASE ")]
            baseline_passed = any(case["name"] == witness and case["passed"] for case in record["cases"])
            caught = baseline_passed and code != 0 and any(case["name"] == witness and not case["passed"] for case in cases)
            record["mutations"].append({"name": name, "witness": witness, "caught": caught, "exitCode": code})
        record["exitCode"] = int(record["baselineExit"] != 0 or record["failed"] != 0
                                 or not all(item["caught"] for item in record["mutations"]))
    except Exception as error:
        record["error"] = str(error)
        record["exitCode"] = 2
    finally:
        record["finishedAt"] = datetime.now(timezone.utc).isoformat()
        record["sourceUnchanged"] = all(hashlib.sha256((root / name).read_bytes()).hexdigest() == digest
                                        for name, digest in hashes.items())
        record["testsUnchanged"] = all(hashlib.sha256((here / name).read_bytes()).hexdigest() == digest
                                       for name, digest in test_hashes.items())
        if not record["sourceUnchanged"] or not record["testsUnchanged"]:
            record["exitCode"] = 2
        (output / "result.json").write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n")
        print(json.dumps({key: record[key] for key in ["output", "cases", "mutations", "exitCode", "sourceUnchanged", "testsUnchanged"]},
                         ensure_ascii=False, indent=2))
        if "error" in record:
            print(record["error"])
    return record["exitCode"]


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(2)

#!/usr/bin/env python3
"""생산 select와 startPipeline을 비활성 어댑터로 컴파일하고 실행한다."""
import hashlib
import json
import os
from datetime import datetime, timezone
from pathlib import Path
import subprocess
import sys


def extract(source, marker):
    if source.count(marker) != 1:
        raise ValueError(f"추출 지점이 유일하지 않습니다: {marker}")
    start = source.index(marker)
    index = source.index("{", start)
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
        elif char == "{":
            depth += 1
        elif char == "}":
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
    output.mkdir(parents=True, exist_ok=True)
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
    inputs = [host, ingress, *protocol, here / "fixture.swift", here / "run.py"]
    hashes = {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
    record = {"sourceCommit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
              "sourceTree": subprocess.check_output(["git", "rev-parse", "HEAD^{tree}"], cwd=root, text=True).strip(),
              "sourceSHA256": hashes, "output": str(output), "commands": [], "cases": [], "mutations": [],
              "startedAt": datetime.now(timezone.utc).isoformat(),
              "limits": ["실제 OS 캡처, AX, 앱, 기기, 서비스, 오디오와 HAL을 사용하지 않습니다.",
                         "select와 startPipeline 전체 본문을 실행하며 handleDockRequest의 AX 조회는 실행하지 않습니다.",
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
                   "private func dockPeerIsCurrent("]
        members = {marker: extract(source, marker) for marker in markers}
        admission = extract(source, "@MainActor\nstruct SourceSelectionAdmission {")
        start = source.index("let admission = SourceSelectionAdmission(isCurrent:")
        end = source.index("            let deadline =", start)
        admission_factory = source[start:end]
        record["extractedSHA256"] = {key: hashlib.sha256(value.encode()).hexdigest()
                                     for key, value in {**members, "SourceSelectionAdmission": admission,
                                                        "Dock admission factory": admission_factory}.items()}
        fixture = (here / "fixture.swift").read_text()
        fixture = fixture.replace("// ADMISSION_TYPE", admission).replace("// PRODUCTION_MEMBERS", "\n".join(members.values()))
        fixture = fixture.replace("// ADMISSION_FACTORY", admission_factory)
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
            ("unguarded-commit", "guard admission.commit(commit) else {", "guard ({ commit(); return true })() else {",
             "capture-start-peer-loss"),
            ("missing-cleanup", "await capture.stop()\n                await syntheticCapture.stop()", "/* cleanup omitted */",
             "capture-start-new-ticket"),
            ("missing-peer-guard", "guard self.dockPeerIsCurrent(connection) else { return false }", "if false { return false }",
             "capture-start-transport-closed"),
        ]
        for name, old, new, witness in mutants:
            if fixture.count(old) != 1:
                raise RuntimeError(f"변이 지점이 유일하지 않습니다: {name}")
            path = output / f"{name}.swift"
            path.write_text(fixture.replace(old, new, 1))
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
        if not record["sourceUnchanged"]:
            record["exitCode"] = 2
        (output / "result.json").write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n")
        print(json.dumps({key: record[key] for key in ["output", "cases", "mutations", "exitCode", "sourceUnchanged"]},
                         ensure_ascii=False, indent=2))
        if "error" in record:
            print(record["error"])
    return record["exitCode"]


if __name__ == "__main__":
    sys.exit(main())

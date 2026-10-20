#!/usr/bin/env python3
"""생산 수신부·선택·최종 확정 본문을 비활성 캡처 경계로 실행한다."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
root, output = (Path(value).resolve() for value in sys.argv[1:])
here = Path(__file__).resolve().parent
emit = sys.argv[2] == '--emit'
if not emit:
    route = json.loads(subprocess.check_output([
        "/Users/ambrion/.local/bin/storage-route", "path", "development-archive", "--project", "CCR-Vision"
    ]))
    assert output.is_relative_to(Path(route["path"]) / "host-native-dock-20261021/pipeline-checks")
    output.mkdir(parents=True, exist_ok=False)
    (output / "tmp").mkdir()
env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer",
           TMPDIR=str(output / "tmp"), CLANG_MODULE_CACHE_PATH=str(output / "module-cache"))
spec = importlib.util.spec_from_file_location("pipeline", root / "Tests/checks/native-dock-pipeline/run.py")
pipeline = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pipeline)
extract = pipeline.extract
source = (root / "Sources/SillHost/StreamCoordinator.swift").read_text()
markers = ["private enum PipelineEpochError:", "private func startPipeline(",
           "func select(_ source: StreamSource,", "private static func epochGeometry(",
           "private func dockPeerIsCurrent(", "private func handleDockRequest(",
           "private func dockActionIsCurrent(", "private func handlePick(", "private func inputAuthorizationCurrent("]
for marker in ["private func remoteSourceAdmission(", "private func handleRemoteSource("]:
    if marker in source:
        markers.append(marker)
members = "\n".join(extract(source, marker) for marker in markers)
template = (root / "Tests/checks/native-dock-pipeline/fixture.swift").read_text().split("enum Revocation:")[0]
template = template.replace("    func handlePick(_ source: StreamSource) async {}\n", "")
old_handle = extract(template, "    func handle(_ message:")
prefix = source[source.index("    private func handle(_ message:"):]
prefix = prefix[:prefix.index("        switch message.kind {")].replace("private func", "func")
branch = source[source.index("        case .selectSource:", source.index("private func handle(_ message:")):]
branch = branch[:branch.index("        case .windowCommand:")]
handle = prefix + "        switch message.kind {\n" + branch + "        default: break\n        }\n    }"
template = template.replace(old_handle, handle)
revision_update = source.split("if active != oldValue {", 1)[1].split("microphoneIngress.revoke()", 1)[0]
template = template.replace('    var active = StreamSource.none', '''    let launchID = "launch-A"
    var sourceRevision: UInt64 = 0
    var active = StreamSource.none {
        didSet { if active != oldValue { ''' + revision_update + ''' } }
    }
    let gestureChords = Chords()''')
template = template.replace('var selectionRevision: String { "검사 선택 세대" }',
                            'var selectionRevision: String { "\\(launchID):\\(sourceRevision)" }')
template = template.replace("// ADMISSION_TYPE", extract(source, "@MainActor\nstruct SourceSelectionAdmission {"))
template = template.replace("// ADMISSION_FACTORY", extract(source, "let admission = SourceSelectionAdmission(", "(", ")"))
template = template.replace("// PRODUCTION_MEMBERS", members)
if "selectionRevision: String? = nil" in (root / "Sources/SillHost/DockSelectionIngress.swift").read_text():
    template = template.replace("displayIDs: [], appBundleIDs: [])",
                                "displayIDs: [], appBundleIDs: [], selectionRevision: selectionRevision)")
template += "\nfinal class Chords { func forget() {} }\n"
generated = output / "Fixture.swift"
if emit:
    print(template + (here / "checks.swift").read_text())
    sys.exit(0)
generated.write_text(template + (here / "checks.swift").read_text())
inputs = [root / "Sources/SillHost/StreamCoordinator.swift", root / "Sources/SillHost/DockSelectionIngress.swift",
          *sorted((root / "Sources/StreamProtocol").glob("*.swift")), here / "run.py", here / "checks.swift",
          root / "Tests/checks/native-dock-pipeline/fixture.swift", root / "Tests/checks/native-dock-pipeline/run.py"]
hashes = {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
record = {"commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
          "tree": subprocess.check_output(["git", "rev-parse", "HEAD^{tree}"], cwd=root, text=True).strip(),
          "workingTree": subprocess.check_output(["git", "status", "--porcelain=v1"], cwd=root, text=True),
          "sourceSHA256": hashes, "commands": [], "cases": [],
          "limits": ["실제 OS 캡처·AX·오디오·HAL·기기·설치·서비스는 실행하지 않음",
                     "기존 pipeline fixture를 재사용하며 수신부는 selectSource 분기만 추출",
                     "active observer는 실제 revision 증가와 거울 전달 부분만 추출",
                     "맥북 로컬 검증: 실제 설치된 macOS SDK와 이 워크트리의 정확한 생산 소스 필요"]}

def run(name, command):
    result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=180)
    log = result.stdout + result.stderr
    (output / (name + ".log")).write_text(log)
    record["commands"].append({"argv": command, "exitCode": result.returncode})
    if result.returncode:
        print(log[-12000:])
    return result.returncode, log

swift = ["/usr/bin/xcrun", "swiftc", "-module-cache-path", str(output / "module-cache")]
code, log = run("protocol", swift + ["-parse-as-library", "-emit-module", "-emit-object", "-whole-module-optimization",
    "-module-name", "StreamProtocol", *map(str, sorted((root / "Sources/StreamProtocol").glob("*.swift"))),
    "-emit-module-path", str(output / "StreamProtocol.swiftmodule"), "-o", str(output / "StreamProtocol.o")])
if not code:
    code, log = run("compile", swift + ["-parse-as-library", "-I", str(output), str(generated),
        str(root / "Sources/SillHost/DockSelectionIngress.swift"), str(output / "StreamProtocol.o"), "-o", str(output / "checks")])
if not code:
    code, log = run("runtime", [str(output / "checks")])
    record["cases"] = [json.loads(line[5:]) for line in log.splitlines() if line.startswith("CASE ")]
record["exitCode"] = code
record["sourceUnchanged"] = all(hashlib.sha256(Path(path).read_bytes()).hexdigest() == value for path, value in hashes.items())
assert record["sourceUnchanged"]
(output / "result.json").write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n")
print(json.dumps({"output": str(output), "exitCode": code, "passed": sum(case["passed"] for case in record["cases"]),
                  "total": len(record["cases"]), "sourceUnchanged": record["sourceUnchanged"]}, ensure_ascii=False))
sys.exit(code)

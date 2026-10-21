import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


root = Path(__file__).resolve().parents[3]
here = Path(__file__).resolve().parent
model = root / 'Sources/SillHost/LocalCursorInputLease.swift'
inputs = [model, here / 'main.swift', here / 'run.py', here / 'README.md']
before = {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}

prologue = '''import Foundation
@main struct Probe {
    @MainActor static func main() throws {
        let model = LocalCursorInputLease(releaseDown: { _, _, _ in })
        let connection = model.openConnection()
        let target = LocalCursorInputLease.Target(pid: 1, windowID: 1, instanceID: "opaque",
            workspace: "opaque", interaction: .windowScoped, captureGeneration: "capture", videoEpoch: UUID())
        let grant = try model.claim(connection, target: target)
'''
negative_cases = {
    '외부 UUID 연결 생성 금지': ('_ = LocalCursorInputLease.Connection(id: UUID())', ['inaccessible']),
    'grant 직접 생성 금지': ('_ = LocalCursorInputLease.Grant(connection: connection, target: target, deadline: 0)', ['inaccessible']),
    '연결 식별자 변경 금지': ('connection.id = UUID()', ["'let' constant"]),
    'grant target 변경 금지': ('grant.target = target', ["'let' constant"]),
    '연결 직렬화 금지': ('_ = try JSONEncoder().encode(connection)', ['Encodable']),
    'grant 직렬화 금지': ('_ = try JSONEncoder().encode(grant)', ['Encodable']),
    '연결 역직렬화 금지': ('_ = try JSONDecoder().decode(LocalCursorInputLease.Connection.self, from: Data())', ['Decodable']),
    'grant 역직렬화 금지': ('_ = try JSONDecoder().decode(LocalCursorInputLease.Grant.self, from: Data())', ['Decodable']),
}
checked_boundaries = []
with tempfile.TemporaryDirectory(prefix='local-cursor-input-lease-') as temporary:
    scratch = Path(temporary)
    compiler = ['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
                '-module-cache-path', str(scratch / 'cache')]
    binary = scratch / 'checks'
    subprocess.run(compiler + [str(model), str(here / 'main.swift'), '-o', str(binary)],
                   check=True, timeout=180)
    subprocess.run([str(binary)], check=True, timeout=30)
    for name, (statement, diagnostics) in negative_cases.items():
        probe = scratch / 'probe.swift'
        probe.write_text(prologue + '        ' + statement + '\n    }\n}\n')
        result = subprocess.run(compiler + ['-typecheck', str(model), str(probe)],
                                capture_output=True, text=True, timeout=60)
        if result.returncode == 0 or not all(text in result.stderr for text in diagnostics):
            raise RuntimeError('컴파일 거절 경계 검사가 실패했습니다: ' + name)
        checked_boundaries.append(name)

after = {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
if after != before:
    raise RuntimeError('검사 중 입력 소스가 변경되었습니다')
print(json.dumps({'passed': True, 'sourceHashes': before, 'sourceUnchanged': True,
                  'scratchRemoved': not scratch.exists(), 'compileRejectedBoundaries': checked_boundaries,
                  'actualInput': 0, 'networkActions': 0, 'deviceOrHALActions': 0,
                  'conversationScopedProductionRefusal': 'conversation_authority_unavailable',
                  'windowScopedResultContract': 'inputPosted'}, ensure_ascii=False))

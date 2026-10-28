#!/usr/bin/env python3
"""Execute the product's PDF request method and list action without opening SwiftUI."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[3]
output = Path(sys.argv[1]).resolve()
archive = json.loads(subprocess.check_output([
    '/Users/ambrion/.local/bin/storage-route', 'path', 'development-archive', '--project', 'BT_CCR-ipad'], text=True))
assert any(parent.exists() and parent.samefile(archive['path']) for parent in [output, *output.parents])
output.mkdir(parents=True, exist_ok=True)
source = Path(sys.argv[2]) if len(sys.argv) > 2 else root / 'iOSClient/CanvasBridge/CanvasWorkspace.swift'
text = source.read_text()
start = text.index('    private func openVaultPDF(')
end = text.index('    private func savePDFExcerpt(', start)
method = text[start:end].replace('private func', 'func', 1)
properties = '\n'.join(line.replace('@State ', '').replace('private ', '') for line in text.splitlines()
                       if re.search(r'\bvar pdf(?:Reader|Loading|Request)\b', line))
list_action = re.search(r'Button\("목록"\) \{ (.*?) \}\.frame', text).group(1)
program = r'''
import Foundation
struct VaultPDFSnapshot { let path: String }
struct VaultPDFExcerpt {}
enum VaultPDFError: LocalizedError { case missing; var errorDescription: String? { "원본 없음" } }
final class VaultPDFReader {
    let path: String
    init(snapshot: VaultPDFSnapshot, source: VaultPDFExcerpt?) throws { path = snapshot.path }
}
@MainActor final class Gate {
    var pending: [String:CheckedContinuation<VaultPDFSnapshot,Error>] = [:]
    func load(_ path: String) async throws -> VaultPDFSnapshot {
        try await withCheckedThrowingContinuation { pending[path] = $0 }
    }
    func wait(_ path: String) async { while pending[path] == nil { await Task.yield() } }
    func finish(_ path: String, error: Bool = false) {
        let c = pending.removeValue(forKey:path)!
        if error { c.resume(throwing:URLError(.timedOut)) }
        else { c.resume(returning:VaultPDFSnapshot(path:path)) }
    }
    func vaultPDF(at path: String) async throws -> VaultPDFSnapshot { try await load(path) }
}
@MainActor final class Store {
    var vaultNote: String? = "열린 원문"
    var vaultDirty = false, vaultSaving = false, vaultInputBusy = false
    struct Scene { var id = UUID() }
    var scene = Scene(), vaultStatus = "원래 상태"
    func closeVaultEditor() -> Bool { vaultNote = nil; return true }
}
@MainActor final class WorkspaceProbe {
    let store = Store(), relay = Gate()
    var relayAddress = "http://fixture.invalid", relayToken = "fixture"
PROPERTIES
    func list() { LIST_ACTION }
METHOD
}
@main struct Checks {
    @MainActor static func main() async {
        var checks = 0, failures = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1; if !value { failures += 1 }
            print("\(value ? "PASS" : "FAIL") \(label)")
        }
        let view = WorkspaceProbe(), oldScene = UUID()
        view.store.scene.id = oldScene
        let first = Task { await view.openVaultPDF("old") }
        await view.relay.wait("old")
        check(view.pdfLoading,"request shows loading before response")
        view.list()
        check(!view.pdfLoading && view.pdfRequest == nil,"list cancellation clears loading immediately")
        view.relay.finish("old"); await first.value
        check(view.pdfReader == nil && view.store.vaultNote == nil && view.store.scene.id == oldScene,
              "cancelled success cannot replace note, reader or scene")

        let race = WorkspaceProbe()
        let earlier = Task { await race.openVaultPDF("earlier") }
        await race.relay.wait("earlier"); race.list()
        race.store.vaultNote = "다른 노트"
        let canStart = !race.pdfLoading
        let later = Task { await race.openVaultPDF("later") }
        if canStart {
            await race.relay.wait("later")
            let request = race.pdfRequest
            race.relay.finish("earlier"); await earlier.value
            check(race.pdfRequest == request && race.pdfLoading && race.pdfReader == nil,
                  "late old completion cannot clear a newer request")
            race.relay.finish("later"); await later.value
            check(!race.pdfLoading && race.pdfReader?.path == "later" && race.store.vaultNote == "다른 노트",
                  "new request succeeds after cancellation and preserves its note")
        } else {
            check(false,"new request can start after list cancellation")
            race.relay.finish("earlier"); await earlier.value; await later.value
        }
        for change in ["note","scene","connection"] {
            for error in [false,true] {
                let changed = WorkspaceProbe()
                let job = Task { await changed.openVaultPDF(change) }
                await changed.relay.wait(change)
                if change == "note" { changed.store.vaultNote = "새 노트" }
                if change == "scene" { changed.store.scene.id = UUID() }
                if change == "connection" { changed.relayToken = "새 연결" }
                changed.relay.finish(change,error:error); await job.value
                check(changed.pdfReader == nil && changed.store.vaultStatus == "원래 상태" && !changed.pdfLoading,
                      "late \(error ? "failure" : "success") after \(change) change has no effect")
            }
        }
        print("RESULT \(checks) assertions, \(failures) failures; extracted product method, SwiftUI not run")
        exit(failures == 0 ? 0 : 1)
    }
}
'''.replace('PROPERTIES', properties).replace('LIST_ACTION', list_action).replace('METHOD', method)
swift = output / 'pdf-loading.swift'
swift.write_text(program)
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer', TMPDIR=str(output))
command = ['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-module-cache-path',
           str(output / 'modules'), str(swift), '-o', str(output / 'check')]
compile_result = subprocess.run(command, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
(output / 'compile.log').write_text(compile_result.stdout)
print(compile_result.stdout, end='')
code = compile_result.returncode
if code == 0:
    result = subprocess.run([str(output / 'check')], env=env, timeout=30, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (output / 'runtime.log').write_text(result.stdout)
    print(result.stdout, end='')
    code = result.returncode
(output / 'result.json').write_text(json.dumps(dict(source=str(source), sourceSHA256=hashlib.sha256(text.encode()).hexdigest(),
    extractedSHA256=hashlib.sha256(program.encode()).hexdigest(), command=command, exitCode=code, UIExecuted=False), indent=2)+'\n')
sys.exit(code)

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[3]
receipt, log_path = map(Path, sys.argv[1:3])
if receipt.exists() or log_path.exists():
    raise SystemExit('Preserve and reconcile the existing attempt')
record = {'scope': '계약 실행 검사와 실제 SDK 타입 검사. 실제 Host, 화면, 음성, 기기, 서비스, HAL, 권한 조작 없음.',
          'commands': [], 'externalEffects': 0}
inputs = [p for folder in ['Sources', 'Tests/checks/source-selection-admission']
          for p in (root / folder).rglob('*.swift')]
hashes = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
record['sourceSHA256'] = hashes
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
try:
    with tempfile.TemporaryDirectory(prefix='ccr-selection-') as tmp, log_path.open('wb') as log:
        out = Path(tmp)
        compiler = '/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc'
        sdk = subprocess.check_output(['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-path'], env=env, text=True).strip()
        base = [compiler, '-swift-version', '5', '-parse-as-library', '-package-name', 'sill',
                '-sdk', sdk, '-target', 'arm64-apple-macosx14.0', '-module-cache-path', str(out / 'cache')]

        def run(args):
            start = log.tell()
            result = subprocess.run(args, cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=240)
            log.flush()
            record['commands'].append({'command': args, 'exitCode': result.returncode,
                'passedAssertions': sum(line.startswith(b'PASS ') for line in log_path.read_bytes()[start:].splitlines())})
            if result.returncode:
                raise RuntimeError('검사 명령 실패')

        protocol = sorted(map(str, (root / 'Sources/StreamProtocol').glob('*.swift')))
        run(base + ['-whole-module-optimization', '-emit-module', '-emit-object', '-module-name', 'StreamProtocol'] + protocol +
            ['-emit-module-path', str(out / 'StreamProtocol.swiftmodule'), '-o', str(out / 'StreamProtocol.o')])
        server = (root / 'Sources/SillHost/StreamServer.swift').read_text()
        start = server.index('            catalog.sourceSelectionAdmission =')
        end = server.index('            catalog.presentationInput =', start)
        decoration = server[start:end]
        record['decorationSHA256'] = hashlib.sha256(decoration.encode()).hexdigest()
        (out / 'Decoration.swift').write_text('''import Foundation
import StreamProtocol
private struct Route { let encrypted: Bool; let pairedName: String? }
private struct Client { let connection: NSObject; let route: Route }
private func decorate(_ input: WindowList, client: Client, sentryAdmission: SentryAdmission) -> WindowList {
    var catalog = input
''' + decoration + '''
    return catalog
}
func decorationChecks() {
    let gate = SentryAdmission(), peer = NSObject(), unknown = NSObject()
    gate.configure(latched: false, persistenceHealthy: true)
    gate.register(ObjectIdentifier(peer), externalRoute: false)
    gate.admit(ObjectIdentifier(peer))
    let input = WindowList(macName: "fixture", windows: [], active: .none,
        sourceSelectionAdmission: SourceSelectionAdmission(generation: 9, ready: true))
    for encrypted in [false, true] {
        for paired in [false, true] {
            for registered in [false, true] {
                let client = Client(connection: registered ? peer : unknown,
                    route: Route(encrypted: encrypted, pairedName: paired ? "fixture" : nil))
                let output = decorate(input, client: client, sentryAdmission: gate)
                Checks.expect((output.sourceSelectionAdmission != nil) == (encrypted && paired && registered),
                    "실제 송신 decoration은 TLS paired 등록 peer에만 신호를 주입함")
                if let signal = output.sourceSelectionAdmission {
                    Checks.expect(signal == gate.sourceSelectionAdmission(for: ObjectIdentifier(peer)),
                        "송신 신호는 정확한 peer의 현재 세대임")
                }
            }
        }
    }
}
''')
        main = (root / 'Tests/checks/source-selection-admission/main.swift').read_text()
        main = main.replace('        codecChecks()', '        decorationChecks()\n        codecChecks()')
        (out / 'Main.swift').write_text(main)
        admission = root / 'Sources/SillHost/SentryAdmission.swift'
        run(base + ['-I', str(out), str(admission), str(out / 'Main.swift'), str(out / 'Decoration.swift'),
                    str(out / 'StreamProtocol.o'), '-o', str(out / 'checks')])
        run([str(out / 'checks')])
        source = admission.read_text()
        seed = '    private var selectionGeneration: UInt64 = 0'
        assert source.count(seed) == 1
        (out / 'Exhaustion.swift').write_text(source.replace(seed,
            '    private var selectionGeneration: UInt64 = SourceSelectionAdmission.maximumGeneration - 1'))
        run(base + ['-I', str(out), str(out / 'Exhaustion.swift'), str(out / 'Main.swift'), str(out / 'Decoration.swift'),
                    str(out / 'StreamProtocol.o'), '-o', str(out / 'exhaustion')])
        run([str(out / 'exhaustion'), '--exhaustion'])
        module_map = out / 'AudioSilence.modulemap'
        module_map.write_text('module AudioSilence { header "' +
            str(root / 'Sources/AudioSilence/include/AudioSilence.h') + '" export * }\n')
        run(base + ['-typecheck', '-I', str(out), '-Xcc', '-fmodule-map-file=' + str(module_map)] +
            sorted(map(str, (root / 'Sources/SillHost').glob('*.swift'))))
        record['sdk'] = sdk
        record['exitCode'] = 0
    record['temporaryFilesRemoved'] = not out.exists()
except Exception as error:
    record.update(error=str(error), exitCode=2)
record['sourceUnchanged'] = all(hashlib.sha256((root / name).read_bytes()).hexdigest() == sha for name, sha in hashes.items())
record['passedAssertions'] = sum(line.startswith('PASS ') for line in log_path.read_text(errors='replace').splitlines())
receipt.write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n')
print(json.dumps({k: v for k, v in record.items() if k not in ['sourceSHA256', 'commands']}, ensure_ascii=False))
sys.exit(record['exitCode'] if record['sourceUnchanged'] else 2)

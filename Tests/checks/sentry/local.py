import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[3]
archive = Path(sys.argv[1]).resolve()
label = sys.argv[2]
privacy = '--privacy' in sys.argv[3:]
legacy_rollback = '--legacy-rollback' in sys.argv[3:]
archive.mkdir(parents=True, exist_ok=True)
receipt, log_path = archive / (label + '.json'), archive / (label + '.log')
if receipt.exists() or log_path.exists():
    raise SystemExit('Preserve and reconcile the existing attempt')
record = {'scope': 'Targeted exact Xcode checks with injected OS boundaries, no devices or installed app execution',
          'reasonLocal': 'Exact installed Xcode SDK adapter typecheck with inert OS boundaries', 'commands': []}
inputs = [p for folder in ['Sources', 'Tests/checks/sentry', 'Tests/checks/host-audio-privacy', 'Tests/checks/local-audio-participants'] for p in (root / folder).rglob('*')
          if p.is_file() and p.suffix in ['.swift', '.py']]
hashes = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
record['sourceSHA256'] = hashes
record['sourceHEAD'] = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
try:
    with tempfile.TemporaryDirectory(prefix='ccr-', dir='/tmp') as tmp, log_path.open('wb') as log:
        out = Path(tmp)
        env['TMPDIR'] = tmp
        def run(command, timeout=120):
            start = log.tell()
            child = subprocess.Popen(command, cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            try:
                code = child.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                code = 124
            finally:
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                child.wait(timeout=5)
            rows = subprocess.check_output(['ps', '-axo', 'pgid=,stat='], text=True)
            gone = not any(int(parts[0]) == child.pid and not parts[1].startswith('Z')
                           for line in rows.splitlines() if len(parts := line.split()) == 2)
            log.flush()
            record['commands'].append({'command': command, 'exitCode': code, 'childrenReaped': gone,
                'passedAssertions': sum(line.startswith(b'PASS ') for line in log_path.read_bytes()[start:].splitlines())})
            return code == 0 and gone
        sdk = subprocess.check_output(['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-path'], env=env, text=True, timeout=10).strip()
        compiler = '/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc'
        base = [compiler, '-swift-version', '5', '-parse-as-library', '-whole-module-optimization', '-package-name', 'sill',
                '-sdk', sdk, '-target', 'arm64-apple-macosx14.0', '-module-cache-path', str(out / 'cache')]
        stub = out / 'CoordinatorTypecheck.swift'
        stub.write_text('import CoreGraphics\nenum StreamCoordinator { static func isSillVirtualDisplay(_ id: CGDirectDisplayID) -> Bool { false } }\n')
        if not run(base + ['-typecheck', str(root / 'Sources/SillHost/HostSentryPlatform.swift'), str(stub)]):
            raise RuntimeError('Actual AppKit platform typecheck failed')
        protocol = sorted(map(str, (root / 'Sources/StreamProtocol').glob('*.swift')))
        if not run([sys.executable, '-B', str(root / 'Tests/checks/sentry/emit-curtains.py'), '--output', str(out / 'fixture')], 20):
            raise RuntimeError('Extraction failed')
        record['extraction'] = json.loads((out / 'fixture/manifest.json').read_text())
        if not run(base + [str(out / 'fixture/NativePanelChecks.swift'), '-o', str(out / 'native-panel-checks')]):
            raise RuntimeError('Actual AppKit invisible panel compilation failed')
        if not run([str(out / 'native-panel-checks')], 20):
            raise RuntimeError('Actual AppKit invisible panel level check failed')
        if not run(base + ['-emit-module', '-emit-object', '-module-name', 'StreamProtocol'] + protocol +
                   ['-emit-module-path', str(out / 'StreamProtocol.swiftmodule'), '-o', str(out / 'StreamProtocol.o')]):
            raise RuntimeError('Protocol compilation failed')
        if not run(base + ['-I', str(out), str(root / 'Sources/SillHost/SentryAdmission.swift'), str(root / 'Sources/SillHost/HostSentry.swift'),
                          str(out / 'fixture/Main.swift'), str(out / 'fixture/CurtainChecks.swift'),
                          str(out / 'StreamProtocol.o'), '-o', str(out / 'checks')]):
            raise RuntimeError('Targeted compilation failed')
        record['extraction'] = json.loads((out / 'fixture/manifest.json').read_text())
        record['checks'] = {'native-panel': True}
        record['checks'].update({name: run([str(out / 'checks')] + args, 20)
                            for name, args in [('curtains', ['--curtains']), ('refresh', ['--refresh']), ('sentry', [])]})
        if privacy:
            package = out / 'privacy'
            if not run([sys.executable, '-B', str(root / 'Tests/checks/host-audio-privacy/emit.py'), '--output', str(package)], 20):
                raise RuntimeError('Privacy extraction failed')
            target = package / 'Sources/HostPrivacyChecks'
            (target / 'ParticipantChecks.swift').write_bytes((root / 'Tests/checks/local-audio-participants/ParticipantChecks.swift').read_bytes())
            main = target / 'Main.swift'
            anchor = '    @MainActor static func main() async {'
            text = main.read_text()
            assert text.count(anchor) == 1
            main.write_text(text.replace(anchor, anchor + '''
        if CommandLine.arguments.contains("--rollback") {
            await localReturnCommitIdentityChecks()
            print("ROLLBACK_CHECKS_COMPLETE")
            return
        }
        if !CommandLine.arguments.contains("--privacy-only") { await participantChecks() }
'''))
            if legacy_rollback:
                old = subprocess.check_output(['git', 'show', '5a8c75a8b7191ec76f84bfb838decc147ac8a8d1:Sources/SillHost/HostSentry.swift'], cwd=root, text=True)
                source = target / 'HostSentry.swift'
                text = source.read_text()
                marker = '    private func restoreFailedReturn('
                assert old.count(marker) == text.count(marker) == 1
                source.write_text(text[:text.index(marker)] + old[old.index(marker):])
                record['rollbackMutantBase'] = '5a8c75a8b7191ec76f84bfb838decc147ac8a8d1'
            sources = sorted(map(str, target.glob('*.swift')))
            if not run(base + ['-I', str(out)] + sources + [str(out / 'StreamProtocol.o'), '-o', str(out / 'privacy-checks')], 180):
                raise RuntimeError('Privacy targeted compilation failed')
            cases = [('rollback', ['--rollback'])]
            if not legacy_rollback:
                cases += [('privacy', ['--privacy-only']), ('participants', [])]
            record['checks'].update({name: run([str(out / 'privacy-checks')] + args, 60) for name, args in cases})
        record['exitCode'] = 0 if all(record['checks'].values()) else 1
    record['temporaryFilesRemoved'] = not out.exists()
except Exception as error:
    record.update(error=str(error), exitCode=2)
record['sourceUnchanged'] = all(hashlib.sha256((root / name).read_bytes()).hexdigest() == sha for name, sha in hashes.items())
record['passedAssertions'] = sum(line.startswith('PASS ') for line in log_path.read_text(errors='replace').splitlines())
receipt.write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n')
print(json.dumps({k: v for k, v in record.items() if k not in ['sourceSHA256', 'commands', 'extraction']}, ensure_ascii=False))
print('RECEIPT ' + str(receipt))
sys.exit(record['exitCode'] if record['sourceUnchanged'] else 2)

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
HOST = ROOT / 'Sources/SillHost/StreamServer.swift'
POLICY = ROOT / 'Sources/SillHost/HomeListenerRecovery.swift'
MARKERS = [
    'private func wire(', 'private func homeListenerFailed(',
    'private func retryHomeListener(', 'private func startHomePathMonitor(',
    'func stopHomeListener()', 'private func stopHomeListenerOnQueue()',
    'func setPeerToPeer(', 'private func beginSwap(', 'private func bindReplacement(',
    'private func settled(', 'private func replacementFailed(', 'func start()',
]


def block(text, marker):
    start = text.index(marker)
    opening = text.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]


def generate(host):
    methods = '\n'.join(block(host, marker) for marker in MARKERS)
    # Only access and scheduling types change. Lifecycle decisions are extracted verbatim.
    methods = methods.replace('private ', '').replace('DispatchWorkItem', 'FakeWorkItem')
    return (HERE / 'Fixture.swift').read_text().replace('// LIFECYCLE_METHODS', methods) + '\n' + (HERE / 'Checks.swift').read_text()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--sdk-build', action='store_true')
    parser.add_argument('--mutants', action='store_true')
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    paths = sorted({ROOT / 'Package.swift', *(ROOT / 'Sources').rglob('*.swift'),
                    *(ROOT / 'Sources').rglob('*.h'), *(ROOT / 'Sources').rglob('*.c'),
                    *(ROOT / 'Sources').rglob('module.modulemap'),
                    *HERE.glob('*.swift'), Path(__file__).resolve()})
    digest = lambda: {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
    before = digest()
    print('INPUT_SHA256 ' + json.dumps(before, sort_keys=True), flush=True)
    host = HOST.read_text()
    source = generate(host)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    compiler = ['xcrun', 'swiftc', '-swift-version', '5', '-sdk', sdk, '-target', 'arm64-apple-macosx14.0',
                '-module-cache-path', str(out / 'cache')]

    def execute(label, program):
        work = out / label
        work.mkdir()
        main_file = work / 'main.swift'
        main_file.write_text(program)
        command = compiler + [str(POLICY), str(main_file), '-o', str(work / 'checks')]
        compiled = subprocess.run(command, capture_output=True, text=True, timeout=120)
        (work / 'compile.log').write_text(compiled.stdout + compiled.stderr)
        if compiled.returncode:
            print(compiled.stdout + compiled.stderr)
            raise RuntimeError(label + ' did not compile')
        result = subprocess.run([str(work / 'checks')], capture_output=True, text=True, timeout=20)
        (work / 'checks.log').write_text(result.stdout + result.stderr)
        return result

    result = execute('checks', source)
    print(result.stdout, end='')
    if result.returncode:
        print(result.stderr)
        return result.returncode

    killed = []
    if args.mutants:
        mutants = {
            'no-recovery': ('beginSwap(recovering: true)', 'return'),
            'stale-listener-state': ('generation == self.swapCount, l === self.listener else { return }',
                                     'true else { return }'),
            'wrong-port': ('recovering ? homeBoundPort : old.port', 'old.port.map { _ in NWEndpoint.Port(rawValue: 4998) }'),
            'stop-keeps-retrying': ('homeRecovery.stop()', 'homeRecovery = HomeListenerRecovery()'),
        }
        for label, (old, new) in mutants.items():
            if old not in source:
                raise RuntimeError('mutation anchor absent: ' + label)
            mutant = execute(label, source.replace(old, new, 1))
            if mutant.returncode == 0:
                raise RuntimeError('survived: ' + label)
            killed.append(label)
        print('PASS mutation detection: ' + ', '.join(killed))

    # The real quit entry point is not replaced by the harness's scheduling stand-ins.
    goodbye = block(host, 'func goodbyeAll(')
    assert 'if goodbye.reason == Goodbye.quit { stopHomeListenerOnQueue() }' in goodbye
    assert goodbye.index('stopHomeListenerOnQueue()') < goodbye.index('for client in clients.values')
    assert 'guard let handler = onListenerFailed else { exit(1) }' in block(host, 'private func homeListenerFailed(')
    assert 'tls: homeDoor?.tlsOptions(), loopback: loopbackOnly' in block(host, 'private func makeListener(')
    print('PASS quit wiring, CLI exit, unchanged TLS and loopback construction boundaries')

    sdk_code = None
    if args.sdk_build:
        env = dict(os.environ)
        env['CLANG_MODULE_CACHE_PATH'] = str(out / 'clang-cache')
        with (out / 'sdk-build.log').open('w') as log:
            sdk_result = subprocess.run(['xcrun', 'swift', 'build', '--target', 'SillHostCore',
                '--scratch-path', str(out / 'core-build'), '--disable-sandbox'], cwd=ROOT, env=env,
                stdout=log, stderr=subprocess.STDOUT, timeout=600)
        sdk_code = sdk_result.returncode
        print((out / 'sdk-build.log').read_text(), flush=True)
        print('SDK SillHostCore compile exit=' + str(sdk_code))

    after = digest()
    if before != after:
        raise RuntimeError('source changed during verification')
    evidence = dict(before=before, after=after, sourceUnchanged=True, macOSSDK=sdk,
                    sourceSHA256=hashlib.sha256(source.encode()).hexdigest(), extractedMethods=MARKERS,
                    deterministicChecks=result.stdout.splitlines()[-1], mutantsKilled=killed,
                    sdkCompileExit=sdk_code, realServiceListeners=0, hostLaunches=0, deviceActions=0,
                    audioActions=0, HTTPRequests=0, independentReview='parent-owned')
    (out / 'source-evidence.json').write_text(json.dumps(evidence, indent=2) + '\n')
    print('SOURCE_EVIDENCE ' + json.dumps(evidence, sort_keys=True), flush=True)
    return sdk_code or 0


if __name__ == '__main__':
    sys.exit(main())

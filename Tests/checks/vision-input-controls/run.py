import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

from extract import ROOT, block, fixture


def hashes(paths):
    return {name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in paths.items()}


def group_members(group):
    result = subprocess.run(['/bin/ps', '-axo', 'pid=,pgid=,stat='],
                            capture_output=True, text=True, check=True, timeout=5)
    return [int(parts[0]) for line in result.stdout.splitlines()
            if len(parts := line.split()) == 3 and int(parts[1]) == group and not parts[2].startswith('Z')]


def cleanup_group(group):
    initial = group_members(group)
    for action, seconds in [(signal.SIGTERM, 1), (signal.SIGKILL, 1)]:
        if not group_members(group):
            break
        try:
            os.killpg(group, action)
        except ProcessLookupError:
            break
        deadline = time.monotonic() + seconds
        while group_members(group) and time.monotonic() < deadline:
            time.sleep(0.05)
    return {'initial': initial, 'remaining': group_members(group)}


def execute(command, timeout):
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               text=True, start_new_session=True)
    timed_out = False
    try:
        log, _ = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
    finally:
        cleanup = cleanup_group(process.pid)
        process.wait(timeout=5)
    if timed_out:
        log, _ = process.communicate(timeout=5)
    return log, {'pid': process.pid, 'exitCode': process.returncode, 'reaped': process.poll() is not None,
                 'timedOut': timed_out, 'processGroup': cleanup}


def callback_mutants(source):
    def edit(marker, transform):
        body = block(source, marker)
        return source.replace(body, transform(body), 1)

    def contacts_first(body):
        zoom = block(body, 'if let zoom = value.second {')
        contacts = block(body, 'if let contacts = value.first {')
        return body.replace(zoom, 'ZOOM_BODY', 1).replace(contacts, zoom, 1).replace('ZOOM_BODY', contacts, 1)

    def finish_first(body):
        finish = 'input.finishGesture(revision: ticket)'
        assert body.count(finish) == 1
        return body.replace(finish, '', 1).replace('admit {', 'admit {\n' + finish, 1)

    return {
        'changed-order': (edit('func changed(', contacts_first),
                          'callback changed magnification wins before contact movement'),
        'ended-order': (edit('func ended(', finish_first),
                        'callback ended dispatches terminal contact before cleanup'),
        'recognizing-cleanup': (edit('func recognizingChanged(', lambda b: b.replace('input.finishGesture(revision: ticket)', '_ = ticket', 1)),
                                'callback recognizing releases held button before modifier'),
        'disappear-cleanup': (edit('func disappeared(', lambda b: b.replace('input.finishGesture(revision: ticket)', '_ = ticket', 1)),
                              'callback disappear releases held button before modifier'),
        'ticket-refresh': (edit('func changed(', lambda b: b.replace('revision ?? input.gestureRevision', 'input.gestureRevision', 1)),
                           'callback queued old values cannot cross geometry boundary'),
    }


def main():
    root, output = [Path(p).resolve() for p in sys.argv[1:3]]
    if root != ROOT:
        raise SystemExit('source root must match this worktree: ' + str(ROOT))
    if output == root or root in output.parents or (output.exists() and any(output.iterdir())):
        raise SystemExit('use a fresh output outside source')
    output.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    deadline = started + 600
    tracked = subprocess.check_output(['git', 'ls-files'], cwd=root, text=True).splitlines()
    production = {name: root / name for name in tracked if not name.startswith('Tests/') and
                  (name.endswith(('.swift', '.pbxproj', '.plist', '.entitlements', '.xcconfig')) or name == 'Package.resolved')}
    harness = {str(path.relative_to(root)): path for path in Path(__file__).parent.iterdir() if path.is_file()}
    harness['Tests/checks/swift_platform.py'] = root / 'Tests/checks/swift_platform.py'
    inputs = production | harness
    files, extraction = fixture()
    inputs.update({name: root / name for name in files if (root / name).is_file()})
    before = {'sourceRoot': str(root), 'productionSHA256': hashes(production), 'inputSHA256': hashes(inputs)}
    generated = output / 'generated'
    for name, contents in files.items():
        path = generated / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents)
    emitted = {name: generated / name for name in files}
    before['emittedSHA256'] = hashes(emitted)
    before['extractionSHA256'] = extraction
    (output / 'manifest-before.json').write_text(json.dumps(before, indent=2) + '\n')
    record = {'scope': 'Verbatim production View callback bodies, session, reducer and transport with inert callback scheduler and Network/SwiftUI DTOs. No SwiftUI recognizer ordering, device or host delivery proof.',
              'sourceRoot': str(root), 'sourceHEAD': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(),
              'extractionSHA256': extraction, 'commands': [], 'exitCode': 2}
    base = ['/usr/bin/xcrun', 'swiftc', '-swift-version', '5', '-package-name', 'sill', '-module-cache-path', str(output / 'cache')]

    def run(command, label, witness=None):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError('600 second suite deadline')
        log, result = execute(command, timeout=min(90, remaining))
        (output / (label + '.log')).write_text(log)
        record['commands'].append({'label': label, 'argv': command, **result})
        if result['processGroup']['remaining']:
            raise RuntimeError(label + ' left live process group descendants')
        if witness is not None:
            caught = not result['timedOut'] and result['exitCode'] != 0 and ('Precondition failed: ' + witness) in log
            record.setdefault('mutants', []).append({'name': label, 'witness': witness, 'caught': caught})
            if not caught:
                raise RuntimeError(label + ' did not fail at expected witness\n' + log[-6000:])
        elif result['timedOut'] or result['exitCode']:
            raise RuntimeError(label + '\n' + log[-6000:])
        return log

    try:
        run([sys.executable, '-B', str(Path(__file__).parent / 'test_extract.py')], 'extraction-contract')
        run([sys.executable, '-B', str(Path(__file__).parent / 'test_runner.py')], 'runner-contract')
        static_log = run([sys.executable, '-B', str(Path(__file__).parent / 'static.py')], 'static')
        record['staticChecks'] = json.loads(static_log)['count']
        groups = [('Network', [generated / 'Network.swift']), ('SwiftUI', [generated / 'SwiftUI.swift']),
                  ('StreamProtocol', sorted((generated / 'Sources/StreamProtocol').glob('*.swift')))]
        for name, sources in groups:
            run(base + ['-parse-as-library', '-emit-module', '-emit-object', '-whole-module-optimization', '-module-name', name] +
                list(map(str, sources)) + ['-emit-module-path', str(output / (name + '.swiftmodule')), '-o', str(output / (name + '.o'))], 'compile-' + name)
        names = ['Client.swift', 'SpatialAdapter.swift', 'SpatialCallbacks.swift', 'LifecycleTests.swift', 'iOSClient/SessionLink.swift', 'iOSClient/KeyChords.swift', 'Sources/SillHost/KeyStrokes.swift',
                 'visionOSClient/VisionPointer.swift', 'visionOSClient/VisionInputSession.swift', 'visionOSClient/VisionInputDebt.swift',
                 'visionOSClient/VisionTextDraft.swift', 'visionOSClient/VisionPresentation.swift', 'visionOSClient/VisionRemoteKey.swift',
                 'Tests/checks/vision-input-controls/SourceInputFence.swift', 'main.swift']
        run(base + ['-I', str(output)] + [str(generated / name) for name in names] +
            [str(output / (name + '.o')) for name, _ in groups] + ['-o', str(output / 'checks')], 'compile-checks')
        log = run([str(output / 'checks')], 'runtime-checks')
        record['assertions'] = int(re.search(r'RESULT_ASSERTIONS (\d+)', log)[1])
        record['lifecycleAssertions'] = int(re.search(r'LIFECYCLE_ASSERTIONS (\d+)', log)[1])
        pointer_sources = ['iOSClient/KeyChords.swift', 'visionOSClient/VisionPointer.swift',
                           'visionOSClient/VisionInputFence.swift', 'visionOSClient/VisionTransition.swift',
                           'Tests/vision-pointer/main.swift']
        run(base + ['-I', str(output)] + [str(generated / name) for name in pointer_sources] +
            [str(output / 'StreamProtocol.o'), '-o', str(output / 'pointer-checks')], 'compile-pointer')
        pointer_log = run([str(output / 'pointer-checks')], 'runtime-pointer')
        record['pointerAssertions'] = int(re.search(r'Vision input: (\d+) behavioral checks', pointer_log)[1])
        for name, (source, witness) in callback_mutants(files['SpatialCallbacks.swift']).items():
            path = output / ('mutant-' + name + '.swift')
            path.write_text(source)
            executable = output / ('mutant-' + name)
            sources = [path if n == 'SpatialCallbacks.swift' else generated / n for n in names]
            run(base + ['-I', str(output)] + list(map(str, sources)) +
                [str(output / (name + '.o')) for name, _ in groups] + ['-o', str(executable)], 'compile-mutant-' + name)
            run([str(executable)], 'runtime-mutant-' + name, witness=witness)
        record['generatedInputsUnchanged'] = all((generated / n).read_text() == value for n, value in files.items())
        record['exitCode'] = 0 if record['generatedInputsUnchanged'] else 2
    except Exception as error:
        record['error'] = str(error)
    after_files, after_extraction = fixture()
    after = {'sourceRoot': str(root), 'productionSHA256': hashes(production), 'inputSHA256': hashes(inputs),
             'emittedSHA256': hashes(emitted), 'extractionSHA256': after_extraction}
    (output / 'manifest-after.json').write_text(json.dumps(after, indent=2) + '\n')
    record['sourceAndEmittedUnchanged'] = before == after and files == after_files
    record['childrenReaped'] = all(command['reaped'] and not command['processGroup']['remaining'] for command in record['commands'])
    record['elapsedSeconds'] = time.monotonic() - started
    if not record['sourceAndEmittedUnchanged'] or not record['childrenReaped']:
        record['exitCode'] = 2
    (output / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps(record))
    return record['exitCode']


if __name__ == '__main__':
    sys.exit(main())

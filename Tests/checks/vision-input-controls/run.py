from dataclasses import asdict, dataclass
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

DEVELOPER_DIR = '/Applications/Xcode.app/Contents/Developer'


@dataclass(frozen=True)
class Process:
    pid: int
    parent: int
    group: int
    state: str
    started: str
    command: str

    @property
    def identity(self):
        return self.pid, self.started, self.command


def time_left(deadline):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError('owned process deadline exhausted')
    return remaining


def process_table(deadline=None):
    timeout = min(5, time_left(deadline)) if deadline is not None else 5
    result = subprocess.run(['/bin/ps', '-ww', '-axo', 'pid=,ppid=,pgid=,stat=,lstart=,args='],
                            capture_output=True, text=True, check=True, timeout=timeout)
    if deadline is not None:
        time_left(deadline)
    table = {}
    for line in result.stdout.splitlines():
        parts = line.split(None, 9)
        if len(parts) != 10:
            raise ValueError('incomplete process identity from ps')
        item = Process(int(parts[0]), int(parts[1]), int(parts[2]), parts[3],
                       ' '.join(parts[4:9]), parts[9])
        if not item.state.startswith('Z'):
            table[item.pid] = item
    if not table:
        raise ValueError('empty process table from ps')
    return table


def compiler_output_bound(item, output):
    if output is None:
        return False
    args = item.command.split()
    executable = Path(args[0])
    compiler_bin = Path(DEVELOPER_DIR) / 'Toolchains/XcodeDefault.xctoolchain/usr/bin'
    if executable.parent != compiler_bin or executable.name not in {'swiftc', 'swift-frontend', 'swift-driver', 'clang', 'clang++', 'ld'}:
        return False
    for flag, value in zip(args, args[1:]):
        if flag in {'-o', '-module-cache-path', '-emit-module-path'}:
            path = Path(value)
            if path.is_absolute() and '..' not in path.parts and output in path.parents:
                return True
    return False


def owned_processes(table, group, owned, output):
    selected = {pid: item for pid, item in table.items()
                if item.group == group or item.identity in owned or compiler_output_bound(item, output)}
    while True:
        children = {pid: item for pid, item in table.items() if item.parent in selected and pid not in selected}
        if not children:
            break
        selected.update(children)
    owned.update({item.identity: item for item in selected.values()})
    return selected


def hashes(paths):
    return {name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in paths.items()}


def group_members(group):
    return [item.pid for item in process_table().values() if item.group == group]


def cleanup_group(group, owned, output, deadline=None):
    if deadline is None:
        deadline = time.monotonic() + 15
    record = {'initial': [], 'remaining': None, 'detachedInitial': [], 'detachedRemaining': None,
              'verified': False, 'signals': []}

    def scan():
        time_left(deadline)
        table = process_table(deadline)
        time_left(deadline)
        return table

    try:
        live = owned_processes(scan(), group, owned, output)
        record['initial'] = [p.pid for p in live.values() if p.group == group]
        record['detachedInitial'] = [asdict(p) for p in live.values() if p.group != group]
        for action in [signal.SIGTERM, signal.SIGKILL]:
            live = owned_processes(scan(), group, owned, output)
            members = [p for p in live.values() if p.group == group]
            if members:
                checked = scan()
                current = [p for p in checked.values() if p.group == group]
                if any(p.identity not in {m.identity for m in members} for p in current):
                    raise RuntimeError('process group identity changed before signal')
                if current:
                    try:
                        time_left(deadline)
                        os.killpg(group, action)
                        record['signals'].append({'group': group, 'signal': action.name,
                                                  'identities': [asdict(p) for p in current]})
                    except ProcessLookupError:
                        pass
            for item in live.values():
                if item.group == group:
                    continue
                current = scan().get(item.pid)
                if current is not None and current.identity == item.identity:
                    try:
                        time_left(deadline)
                        os.kill(item.pid, action)
                        record['signals'].append({'pid': item.pid, 'signal': action.name,
                                                  'identity': asdict(current)})
                    except ProcessLookupError:
                        pass
            wait_until = min(deadline, time.monotonic() + 1)
            while time.monotonic() < wait_until:
                live = owned_processes(scan(), group, owned, output)
                if not live:
                    break
                time.sleep(min(0.05, time_left(deadline)))
            if not live:
                break
        live = owned_processes(scan(), group, owned, output)
        record['remaining'] = [p.pid for p in live.values() if p.group == group]
        record['detachedRemaining'] = [asdict(p) for p in live.values() if p.group != group]
        record['verified'] = not live
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        record['error'] = str(error)
    record['ownedIdentities'] = [asdict(p) for p in owned.values()]
    return record


def execute(command, timeout, output=None, deadline=None):
    command_deadline = time.monotonic() + timeout
    if deadline is None:
        deadline = command_deadline + 15
    command_deadline = min(command_deadline, deadline)
    environment = dict(os.environ, DEVELOPER_DIR=DEVELOPER_DIR)
    if output is not None:
        environment['VISION_RUNNER_TEST_OUTPUT'] = str(output)
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               text=True, start_new_session=True, env=environment)
    owned = {}
    timed_out = False
    log = ''
    observation_error = None
    try:
        while True:
            remaining = command_deadline - time.monotonic()
            if remaining <= 0:
                timed_out = True
                break
            owned_processes(process_table(deadline), process.pid, owned, output)
            remaining = command_deadline - time.monotonic()
            if remaining <= 0:
                timed_out = True
                break
            try:
                log, _ = process.communicate(timeout=min(0.1, remaining))
                break
            except subprocess.TimeoutExpired:
                continue
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        observation_error = str(error)
    finally:
        cleanup = cleanup_group(process.pid, owned, output, deadline)
        try:
            log, _ = process.communicate(timeout=min(5, time_left(deadline)))
        except (subprocess.TimeoutExpired, TimeoutError):
            cleanup['verified'] = False
            cleanup['error'] = 'owned command did not close after cleanup'
        if observation_error is not None:
            cleanup['verified'] = False
            cleanup['observationError'] = observation_error
    return log, {'pid': process.pid, 'exitCode': process.returncode, 'reaped': process.poll() is not None,
                 'timedOut': timed_out, 'developerDir': DEVELOPER_DIR,
                 'ownershipOutput': str(output) if output is not None else None, 'processGroup': cleanup}


def callback_mutants(source):
    def edit(marker, transform):
        body = block(source, marker)
        return source.replace(body, transform(body), 1)

    def contacts_first(body):
        zoom = block(body, 'if let zoom = value.second {')
        contacts = block(body, 'if let contacts = value.first {')
        return body.replace(zoom, 'ZOOM_BODY', 1).replace(contacts, zoom, 1).replace('ZOOM_BODY', contacts, 1)

    def finish_first(body):
        finish = 'input.finishGesture(revision: ticket, allowMomentum: true)'
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
    if any(character.isspace() for character in str(output)):
        raise SystemExit('output path must not contain whitespace for exact process argument binding')
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
              'sourceTree': subprocess.check_output(['git', 'rev-parse', 'HEAD^{tree}'], cwd=root, text=True).strip(),
              'developerDir': DEVELOPER_DIR,
              'extractionSHA256': extraction, 'commands': [], 'exitCode': 2}
    base = ['/usr/bin/xcrun', 'swiftc', '-swift-version', '5', '-package-name', 'sill', '-module-cache-path', str(output / 'cache')]

    def run(command, label, witness=None):
        remaining = deadline - time.monotonic()
        if remaining <= 15:
            raise TimeoutError('600 second suite deadline')
        log, result = execute(command, timeout=min(90, remaining - 15), output=output, deadline=deadline)
        (output / (label + '.log')).write_text(log)
        record['commands'].append({'label': label, 'argv': command, **result})
        if not result['processGroup']['verified']:
            raise RuntimeError(label + ' owned process cleanup unverified')
        if witness is not None:
            caught = not result['timedOut'] and result['exitCode'] != 0 and ('Precondition failed: ' + witness) in log
            record.setdefault('mutants', []).append({'name': label, 'witness': witness, 'caught': caught})
            if not caught:
                raise RuntimeError(label + ' did not fail at expected witness\n' + log[-6000:])
        elif result['timedOut'] or result['exitCode']:
            raise RuntimeError(label + '\n' + log[-6000:])
        return log

    try:
        record['toolchain'] = {
            'developerDir': DEVELOPER_DIR,
            'globalSelected': run(['/usr/bin/env', '-u', 'DEVELOPER_DIR', '/usr/bin/xcode-select', '-p'], 'global-toolchain').strip(),
            'swiftc': run(['/usr/bin/xcrun', '--find', 'swiftc'], 'child-swiftc').strip(),
            'sdk': run(['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-path'], 'child-sdk').strip(),
            'version': run(['/usr/bin/xcrun', 'swiftc', '--version'], 'child-swift-version').strip(),
        }
        run([sys.executable, '-B', str(Path(__file__).parent / 'test_extract.py')], 'extraction-contract')
        run([sys.executable, '-B', str(Path(__file__).parent / 'test_runner.py')], 'runner-contract')
        static_log = run([sys.executable, '-B', str(Path(__file__).parent / 'static.py')], 'static')
        record['staticChecks'] = json.loads(static_log)['count']
        groups = [('Network', [generated / 'Network.swift']), ('SwiftUI', [generated / 'SwiftUI.swift']),
                  ('StreamProtocol', sorted((generated / 'Sources/StreamProtocol').glob('*.swift')))]
        for name, sources in groups:
            run(base + ['-parse-as-library', '-emit-module', '-emit-object', '-whole-module-optimization', '-module-name', name] +
                list(map(str, sources)) + ['-emit-module-path', str(output / (name + '.swiftmodule')), '-o', str(output / (name + '.o'))], 'compile-' + name)
        names = ['Client.swift', 'SpatialAdapter.swift', 'SpatialCallbacks.swift', 'LifecycleTests.swift', 'ScrollMomentum.swift', 'MomentumDriver.swift', 'iOSClient/SessionLink.swift', 'iOSClient/KeyChords.swift', 'Sources/SillHost/KeyStrokes.swift',
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
    record['childrenReaped'] = bool(record['commands']) and all(
        command['reaped'] and command['processGroup']['verified'] and
        command['processGroup']['remaining'] == [] and command['processGroup']['detachedRemaining'] == []
        for command in record['commands'])
    record['elapsedSeconds'] = time.monotonic() - started
    if not record['sourceAndEmittedUnchanged'] or not record['childrenReaped']:
        record['exitCode'] = 2
    (output / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps(record))
    return record['exitCode']


if __name__ == '__main__':
    sys.exit(main())

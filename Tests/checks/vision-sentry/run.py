#!/usr/bin/env python3
"""Parent-only runner: python3 -B run.py SOURCE_ROOT NEW_PARENT_RAM_OUTPUT.

Use the parent's existing approved RAM execution path. No app, device or host I/O.
The delegate supplies this runner without executing it.
"""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import sys
import time

PROTOCOL = ['Switcher', 'StreamMessage', 'AudioRouting', 'AudioPrivacy', 'Compatibility', 'Sentry']


def prepare(root):
    stream = (root / 'iOSClient/StreamClient.swift').read_text()
    view = (root / 'visionOSClient/SillVisionApp.swift').read_text()
    controller = (root / 'visionOSClient/VisionSentryController.swift').read_text()
    adapter = (root / 'visionOSClient/StreamClient+VisionSentry.swift').read_text()
    storage = stream[stream.index('    @Published var visionSentrySnapshot ='):stream.index('    var visionSentryTrusted:')]
    stub = (root / 'Tests/checks/vision-sentry/Standins.swift').read_text().replace(
        '    // PRODUCTION_SENTRY_STORAGE', storage.replace('@Published ', ''))
    checks = {
        'native ornament independent of input controls': '.ornament(attachmentAnchor: .scene(.bottom)' in view and
            'client.visionSentrySnapshot.available' in view and 'client.activateVisionSentry()' in view,
        'catalog observed on network queue before UI dispatch': stream.index('observeVisionSentry(list, from: peer)') <
            stream.index('receiveVisionAudioCatalogBarrier(list)'),
        'disconnect and handover clear Sentry binding': 'self.bindVisionSentry(to: nil)' in stream and
            'bindVisionSentry(to: c)' in stream and 'bindVisionSentry(to: newValue)' in stream,
        'malformed catalog clears status': 'invalidateVisionSentryCatalog(from: peer)' in stream,
        'send uses exact peer and cancellable submission': 'link.send(bytes, onlyOn: expected, submission: submission)' in adapter,
        'native action has finite final send deadline': 'SessionLink.Submission(deadline: now + VisionSentryController.timeout)' in adapter,
        'adapter leaves input and audio state alone': all(name not in adapter for name in
            ['setInput', 'releaseAll', 'microphoneSet', 'resetVisionAudio', 'setAudio']),
        'no withdrawn account contract consumption': all(name not in adapter + storage for name in
            ['accountScope', 'accountEpoch', 'catalogRevision', 'projectionKind']),
        'local return and OS limits visible in Korean': 'Mac에서 새로 시스템 인증' in view and '전원 버튼·운영체제 보안 화면' in view,
        'Sentry product copy localized': 'Button("센츄리 보호 켜기"' in view and
            re.search(r'"[^"\n]*Sentry[^"\n]*"', controller + view) is None,
    }
    project = plistlib.loads((root / 'SillVision.xcodeproj/project.pbxproj').read_bytes())['objects']
    for name in ['VisionSentryController', 'StreamClient+VisionSentry']:
        path = 'visionOSClient/' + name + '.swift'
        ref = hashlib.sha1(path.encode()).hexdigest().upper()[:24]
        build = hashlib.sha1((path + '.build').encode()).hexdigest().upper()[:24]
        checks['project membership ' + name] = project[ref]['path'] == path and project[build]['fileRef'] == ref and any(
            item['isa'] == 'PBXSourcesBuildPhase' and build in item['files'] for item in project.values())
    failed = [name for name, passed in checks.items() if not passed]
    if failed:
        raise AssertionError(failed)
    files = {'Client.swift': stub, 'Network.swift': (root / 'Tests/checks/vision-input-controls/Network.swift').read_text()}
    for path in ['visionOSClient/VisionSentryController.swift', 'visionOSClient/StreamClient+VisionSentry.swift',
                 'iOSClient/SessionLink.swift', 'Tests/checks/vision-sentry/main.swift'] + [
                     'Sources/StreamProtocol/' + name + '.swift' for name in PROTOCOL]:
        files[path] = (root / path).read_text()
    manifest = {name: hashlib.sha256(value.encode()).hexdigest() for name, value in files.items()}
    manifest['productionStorage'] = hashlib.sha256(storage.encode()).hexdigest()
    return files, manifest, checks


def main():
    if len(sys.argv) != 3:
        raise SystemExit('usage: run.py SOURCE_ROOT NEW_PARENT_RAM_OUTPUT')
    root, output = [Path(value).resolve() for value in sys.argv[1:]]
    if root == output or root in output.parents or output in root.parents or (output.exists() and any(output.iterdir())):
        raise SystemExit('source and new output must be distinct; parent supplies RAM output')
    output.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    record = {'scope': 'actual Sentry controller, adapter and SessionLink; inert Network; UI static only; no host/device/SDK acceptance',
              'commands': [], 'exitCode': 2}
    tracked = [path for folder in ['visionOSClient', 'iOSClient', 'Sources/StreamProtocol', 'Tests/checks/vision-sentry']
               for path in (root / folder).glob('*.swift')]
    tracked += list((root / 'Tests/checks/vision-sentry').glob('*.py'))
    tracked += [root / 'SillVision.xcodeproj/project.pbxproj', root / 'Scripts/make-vision-project.py',
                root / 'Tests/checks/vision-input-controls/Network.swift']
    hashes = {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in tracked}
    record['sourceSHA256'] = hashes
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE='1', TMPDIR=str(output / 'tmp'))
    Path(env['TMPDIR']).mkdir(exist_ok=True)
    base = ['/usr/bin/xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', str(output / 'cache')]

    def run(command, label):
        remaining = 600 - (time.monotonic() - started)
        if remaining <= 0:
            raise TimeoutError('600 second suite budget exhausted')
        child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                 text=True, env=env, start_new_session=True)
        timed_out = False
        try:
            log, _ = child.communicate(timeout=min(90, remaining))
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(child.pid, signal.SIGTERM)
            try:
                log, _ = child.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                log, _ = child.communicate(timeout=5)
        (output / (label + '.log')).write_text(log)
        record['commands'].append({'label': label, 'command': command, 'exitCode': child.returncode,
                                   'timeout': timed_out, 'reaped': child.poll() is not None})
        if timed_out or child.returncode:
            raise RuntimeError(label + ' failed\n' + log[-6000:])
        return log

    try:
        files, record['extractedSHA256'], record['staticContracts'] = prepare(root)
        generated = output / 'generated'
        for name, contents in files.items():
            path = generated / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(contents)
        modules = [('Network', ['Network.swift']), ('StreamProtocol', [
            'Sources/StreamProtocol/' + name + '.swift' for name in PROTOCOL])]
        for name, paths in modules:
            run(base + ['-parse-as-library', '-whole-module-optimization', '-emit-module', '-emit-object', '-module-name', name] +
                [str(generated / path) for path in paths] + ['-emit-module-path', str(output / (name + '.swiftmodule')),
                '-o', str(output / (name + '.o'))], 'compile-' + name)
        sources = ['Client.swift', 'iOSClient/SessionLink.swift', 'visionOSClient/VisionSentryController.swift',
                   'visionOSClient/StreamClient+VisionSentry.swift', 'Tests/checks/vision-sentry/main.swift']
        # Swift's executable entry file must be named main.swift even when its parent is nested.
        run(base + ['-D', 'VISION_SENTRY_CHECKS', '-I', str(output)] + [str(generated / path) for path in sources] +
            [str(output / (name + '.o')) for name, _ in modules] + ['-o', str(output / 'checks')], 'compile-checks')
        log = run([str(output / 'checks')], 'runtime-checks')
        match = re.search(r'^RESULT_ASSERTIONS (\d+)$', log, re.M)
        if not match:
            raise RuntimeError('runtime assertion count missing')
        record['assertions'] = int(match[1])
        record['generatedInputsUnchanged'] = all(hashlib.sha256((generated / name).read_bytes()).hexdigest() == digest
                                                for name, digest in record['extractedSHA256'].items() if name in files)
        record['exitCode'] = 0 if record['generatedInputsUnchanged'] else 2
    except Exception as error:
        record['error'] = str(error)
    record['sourceUnchanged'] = all(hashlib.sha256((root / name).read_bytes()).hexdigest() == digest for name, digest in hashes.items())
    if not record['sourceUnchanged']:
        record['exitCode'] = 2
    (output / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
    print('RESULT_JSON ' + json.dumps(record), flush=True)
    return record['exitCode']


if __name__ == '__main__':
    sys.exit(main())

#!/usr/bin/env python3
"""Parent-only runner. python3 -B run.py SOURCE_ROOT NEW_PARENT_RAM_OUTPUT.

Compiles the pure model, unmodified production adapter and actual SessionLink against
inert Network and fake input/audio/release I/O. No app launch or external delivery.
"""
import hashlib
import importlib.util
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


def block(source, marker):
    start = source.index(marker)
    opening = source.index('{', start)
    depth, position = 1, opening + 1
    while depth:
        if source.startswith('//', position):
            position = source.index('\n', position)
            continue
        if source[position] == '"':
            position += 1
            while source[position] != '"':
                position += 2 if source[position] == '\\' else 1
            position += 1
            continue
        depth += (source[position] == '{') - (source[position] == '}')
        position += 1
    return source[start:position]


def prepare(root):
    selector = root / 'Tests/checks/swift_platform.py'
    spec = importlib.util.spec_from_file_location('display_platform', selector)
    platform = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(platform)
    stream = (root / 'iOSClient/StreamClient.swift').read_text()
    view = (root / 'visionOSClient/SillVisionApp.swift').read_text()
    chooser = (root / 'visionOSClient/VisionDisplayChooser.swift').read_text()
    request = block(stream, 'private func request(_ source:')
    storage = stream[stream.index('    @Published var visionDisplaySelection ='):stream.index('    var visionStartupStarted =')]
    stub = (root / 'Tests/checks/vision-display-selection/Standins.swift').read_text()
    stub = stub.replace('    // PRODUCTION_DISPLAY_STORAGE', storage.replace('@Published', '@SwiftUI.Published'))
    stub = stub.replace('    // PRODUCTION_REQUEST', platform.select_platform(request, vision=True))
    background = block(stream, 'private func wentToBackground(')
    resign = next(line.strip() for line in background.splitlines() if 'admitVisionDisplays(' in line)
    stub = stub.replace('    // PRODUCTION_RESIGN', 'func appWillResign() { ' + resign + ' }')
    checks = {
        'chooser outside input disabling': 'openDisplayChooser' not in block(view, 'private var controls:') and
            'Button("전체 화면", action: openDisplayChooser)' in view and '.disabled(!input.canSend || draftShown)' in view,
        'chooser usable with no active source': 'guard phase == .active, client.connected, !transitions.isPending' in block(view, 'private func openDisplayChooser()'),
        'bounded scrolling keeps status and close reachable': 'ScrollView {' in chooser and 'LazyVStack' in chooser and '.frame(maxHeight: 320)' in chooser,
        'checkmark follows observed state': 'observedDisplay == display.id' in chooser,
        'UI uses structured command': 'client.selectVisionDisplay(command)' in view and 'requestID: UUID(), displayID: display.id, token: token' in chooser,
        'pending and modal gate native input': '!client.visionDisplaySelection.inputBlocked' in (root / 'visionOSClient/VisionInputSession.swift').read_text(),
        'pending gates source and draft': '!visionDisplaySelection.inputBlocked' in request and '!visionDisplaySelection.inputBlocked' in block(stream, 'func captureVisionTextTarget()'),
        'automatic paths guarded for Vision': '#if os(visionOS)\n                if self.visionDisplaySelection.blocksDesktopRequest' in stream,
        'iPad request has no display change': 'visionDisplaySelection' not in platform.select_platform(request, vision=False),
        'adapter uses cancellable SessionLink only': 'visionDisplayLink.send(bytes, onlyOn: expected, submission: submission)' in (root / 'visionOSClient/StreamClient+VisionDisplaySelection.swift').read_text(),
        'native application admission checks actual active state': 'UIApplication.shared.applicationState == .active' in
            (root / 'visionOSClient/StreamClient+VisionDisplaySelection.swift').read_text(),
        'willResign cancels before microphone suspension': background.index('admitVisionDisplays(') < background.index('microphoneApplicationActive(false)'),
        'no production driver injection': 'VISION_DISPLAY_CHECKS' not in (root / 'Scripts/make-vision-project.py').read_text(),
    }
    project = plistlib.loads((root / 'SillVision.xcodeproj/project.pbxproj').read_bytes())['objects']
    for name in ['VisionDisplaySelection', 'StreamClient+VisionDisplaySelection', 'VisionDisplayChooser']:
        path = 'visionOSClient/' + name + '.swift'
        ref = hashlib.sha1(path.encode()).hexdigest().upper()[:24]
        build = hashlib.sha1((path + '.build').encode()).hexdigest().upper()[:24]
        checks['project membership ' + name] = project[ref]['path'] == path and project[build]['fileRef'] == ref and any(
            item['isa'] == 'PBXSourcesBuildPhase' and build in item['files'] for item in project.values())
    version = re.search(r"'CURRENT_PROJECT_VERSION': '([1-9][0-9]*)'", (root / 'Scripts/make-vision-project.py').read_text())
    checks['build versions match generator'] = version is not None and [item['buildSettings']['CURRENT_PROJECT_VERSION'] for item in project.values()
        if item['isa'] == 'XCBuildConfiguration' and 'CURRENT_PROJECT_VERSION' in item['buildSettings']] == [version[1], version[1]]
    failed = [name for name, passed in checks.items() if not passed]
    if failed:
        raise AssertionError(failed)
    files = {'Client.swift': stub, 'Lease.swift': 'import Foundation\n' + block(
        (root / 'visionOSClient/VisionCableBootstrap.swift').read_text(), 'struct VisionWindowLease:'),
        'Network.swift': (root / 'Tests/checks/vision-input-controls/Network.swift').read_text(),
        'SwiftUI.swift': (root / 'Tests/checks/vision-input-controls/SwiftUI.swift').read_text()}
    for path in ['visionOSClient/VisionDisplaySelection.swift', 'visionOSClient/StreamClient+VisionDisplaySelection.swift',
                 'iOSClient/SessionLink.swift', 'Tests/checks/vision-display-selection/main.swift'] + [
                     'Sources/StreamProtocol/' + name + '.swift' for name in PROTOCOL]:
        files[path] = (root / path).read_text()
    manifest = {name: hashlib.sha256(value.encode()).hexdigest() for name, value in files.items()}
    manifest['productionStorage'] = hashlib.sha256(storage.encode()).hexdigest()
    manifest['productionRequest'] = hashlib.sha256(request.encode()).hexdigest()
    manifest['productionResign'] = hashlib.sha256(resign.encode()).hexdigest()
    return files, manifest, checks


def main():
    if len(sys.argv) != 3:
        raise SystemExit('usage: run.py SOURCE_ROOT NEW_PARENT_RAM_OUTPUT')
    root, output = [Path(value).resolve() for value in sys.argv[1:]]
    if root == output or root in output.parents or output in root.parents or (output.exists() and any(output.iterdir())):
        raise SystemExit('source and new output must be distinct; parent supplies RAM output')
    output.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    record = {'scope': 'pure model, actual adapter and actual SessionLink; inert Network; fake input/audio/release; UI static only; no host/device/SDK acceptance',
              'commands': [], 'exitCode': 2}
    tracked = [path for folder in ['visionOSClient', 'iOSClient', 'Sources/StreamProtocol', 'Tests/checks/vision-display-selection']
               for path in (root / folder).glob('*.swift')]
    tracked += list((root / 'Tests/checks/vision-display-selection').glob('*.py'))
    tracked += [root / 'SillVision.xcodeproj/project.pbxproj', root / 'Scripts/make-vision-project.py']
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
        modules = [('Network', ['Network.swift']), ('SwiftUI', ['SwiftUI.swift']), ('StreamProtocol', [
            'Sources/StreamProtocol/' + name + '.swift' for name in PROTOCOL])]
        for name, paths in modules:
            run(base + ['-parse-as-library', '-whole-module-optimization', '-emit-module', '-emit-object', '-module-name', name] +
                [str(generated / path) for path in paths] + ['-emit-module-path', str(output / (name + '.swiftmodule')),
                '-o', str(output / (name + '.o'))], 'compile-' + name)
        sources = ['Client.swift', 'Lease.swift', 'iOSClient/SessionLink.swift', 'visionOSClient/VisionDisplaySelection.swift',
                   'visionOSClient/StreamClient+VisionDisplaySelection.swift', 'Tests/checks/vision-display-selection/main.swift']
        # Swift's executable entry file must be named main.swift even when its parent is nested.
        run(base + ['-D', 'VISION_DISPLAY_CHECKS', '-I', str(output)] + [str(generated / path) for path in sources] +
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

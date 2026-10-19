#!/usr/bin/env python3
"""Parent-only source fixture runner: run.py SOURCE_ROOT NEW_PARENT_RAM_OUTPUT.

Actual catalog/model/adapter and verbatim view delegate/store bodies, with inert Network/WebKit
shapes. Does not prove TLS verification, real WebKit behavior, native SDK or device acceptance.
"""
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys

PROTOCOL = ['Switcher', 'StreamMessage', 'AudioRouting', 'AudioPrivacy', 'Sentry', 'TestDestinations']


def body(source, marker):
    start = source.index(marker)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


def main():
    if len(sys.argv) != 3:
        raise SystemExit('usage: run.py SOURCE_ROOT NEW_PARENT_RAM_OUTPUT')
    root, output = [Path(value).resolve() for value in sys.argv[1:]]
    if root == output or root in output.parents or output in root.parents or (output.exists() and any(output.iterdir())):
        raise SystemExit('parent must supply a distinct new RAM output directory')
    output.mkdir(parents=True, exist_ok=True)
    paths = ['Sources/StreamProtocol/' + name + '.swift' for name in PROTOCOL]
    paths += ['visionOSClient/VisionTestDestinations.swift', 'visionOSClient/StreamClient+VisionTestDestinations.swift',
              'visionOSClient/VisionTestDestinationsView.swift', 'iOSClient/StreamClient.swift',
              'Tests/checks/vision-input-controls/Network.swift']
    paths += ['Tests/checks/vision-test-destinations/' + name for name in
              ['main.swift', 'AdapterFixture.swift', 'WebViewFixture.swift', 'catalog.json', 'run.py', 'run.sh']]
    originals = {name: (root / name).read_bytes() for name in paths}
    hashes = {name: hashlib.sha256(data).hexdigest() for name, data in originals.items()}
    text = lambda name: originals[name].decode()
    client = text('iOSClient/StreamClient.swift')
    storage = client[client.index('    @Published var visionTestDestinations ='):client.index('    @Published var visionSentrySnapshot =')]
    fixture = text('Tests/checks/vision-test-destinations/AdapterFixture.swift').replace(
        '    // PRODUCTION_TEST_DESTINATION_STORAGE', storage.replace('@Published ', ''))
    view = text('visionOSClient/VisionTestDestinationsView.swift')
    # Inert fixture runs on main. Only enclosing platform/actor declarations are excluded;
    # delegate and store method bodies remain verbatim from the production view source.
    view_bodies = 'import Foundation\nimport StreamProtocol\n' + body(view, 'final class VisionTestDestinationStores:') + '\n' + body(view, 'final class Coordinator:')
    view_bodies += '''
struct VisionWebViewFixture {
    @Binding var model: VisionTestDestinations
    let selection: VisionTestDestinations.Selection
    let store: WKWebsiteDataStore
    typealias Context = FixtureContext
'''
    for marker in ['func makeCoordinator()', 'func makeUIView(context:', 'func updateUIView(', 'static func dismantleUIView(']:
        view_bodies += body(view, marker) + '\n'
    view_bodies += '}\n'
    (output / 'Client.swift').write_text(fixture)
    (output / 'ViewBodies.swift').write_text(view_bodies)
    record = {'scope': __doc__, 'sourceSHA256': hashes, 'commands': [], 'exitCode': 2,
              'viewBodiesSHA256': hashlib.sha256(view_bodies.encode()).hexdigest(),
              'productionStorageSHA256': hashlib.sha256(storage.encode()).hexdigest()}
    env = dict(os.environ, TMPDIR=str(output / 'tmp'), PYTHONDONTWRITEBYTECODE='1')
    Path(env['TMPDIR']).mkdir()
    base = ['/usr/bin/xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', str(output / 'cache')]

    def run(command, label):
        child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                 text=True, env=env, start_new_session=True)
        timed_out = False
        try:
            log, _ = child.communicate(timeout=90)
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
        for name, sources in [('Network', [root / 'Tests/checks/vision-input-controls/Network.swift']),
                              ('StreamProtocol', [root / 'Sources/StreamProtocol' / (name + '.swift') for name in PROTOCOL])]:
            run(base + ['-parse-as-library', '-whole-module-optimization', '-emit-module', '-emit-object', '-module-name', name] +
                [str(path) for path in sources] + ['-emit-module-path', str(output / (name + '.swiftmodule')),
                '-o', str(output / (name + '.o'))], 'compile-' + name)
        sources = [output / 'Client.swift', output / 'ViewBodies.swift', root / 'visionOSClient/VisionTestDestinations.swift',
                   root / 'visionOSClient/StreamClient+VisionTestDestinations.swift',
                   root / 'Tests/checks/vision-test-destinations/WebViewFixture.swift',
                   root / 'Tests/checks/vision-test-destinations/main.swift']
        run(base + ['-D', 'VISION_TEST_DESTINATION_CHECKS', '-I', str(output)] + [str(path) for path in sources] +
            [str(output / (name + '.o')) for name in ['Network', 'StreamProtocol']] + ['-o', str(output / 'checks')], 'compile-checks')
        log = run([str(output / 'checks'), str(root / 'Tests/checks/vision-test-destinations/catalog.json')], 'behavior')
        if ' checks, 0 failures' not in log:
            raise RuntimeError('behavioral assertion result missing')
        record['exitCode'] = 0
    except Exception as error:
        record['error'] = str(error)
    record['sourceUnchanged'] = all((root / name).read_bytes() == data for name, data in originals.items())
    if not record['sourceUnchanged']:
        record['exitCode'] = 2
    (output / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps(record), flush=True)
    return record['exitCode']


if __name__ == '__main__':
    sys.exit(main())

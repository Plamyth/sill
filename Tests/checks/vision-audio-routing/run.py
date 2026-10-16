"""Parent-only compiler driver. --emit-only prepares fixtures without compiling."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time
from extract import fixture
from static import checks


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('root', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--emit-only', action='store_true')
    args = parser.parse_args()
    root, output = args.root.resolve(), args.output.resolve()
    if root == output or root in output.parents:
        raise SystemExit('OUTPUT must be outside source ROOT')
    output.mkdir(parents=True, exist_ok=True)
    if (output / 'result.json').exists():
        raise SystemExit('Reconcile prior result before reusing OUTPUT')
    here = root / 'Tests/checks/vision-audio-routing'
    inputs = sorted((root / 'Sources/StreamProtocol').glob('*.swift'))
    inputs += [root / name for name in ['iOSClient/MacAudioRouteSession.swift', 'iOSClient/MacAudioRouteTransport.swift',
        'iOSClient/SessionLink.swift', 'iOSClient/StreamClient.swift', 'visionOSClient/VisionMacAudioController.swift',
        'visionOSClient/VisionMacAudioTransport.swift', 'visionOSClient/VisionMacAudioStatus.swift', 'visionOSClient/VisionCableBootstrap.swift',
        'visionOSClient/VisionInputSession.swift', 'visionOSClient/SillVisionApp.swift']]
    inputs += sorted(here.glob('*.py')) + sorted(here.glob('*.swift')) + sorted((here / 'shared').glob('*'))
    originals = {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs if path.is_file()}
    started = time.monotonic()
    record = {'scope': 'Shared 65 policy and 16 transport checks plus actual extracted Vision adapter/modal and native controller with inert Network. No UI rendering, TLS cryptography, native audio IO or host effect proof.',
              'commands': [], 'assertions': {}, 'sourceSHA256': originals, 'exitCode': 2}
    generated = output / 'generated'
    generated.mkdir()
    emitted = {}

    def write(group, name, text):
        path = generated / group / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        emitted[str(path.relative_to(generated))] = hashlib.sha256(text.encode()).hexdigest()
        return path

    def flat(path):
        return path.read_text().replace('import StreamProtocol\n', '')

    transport = (root / 'iOSClient/MacAudioRouteTransport.swift').read_text()
    prefix, suffix = '#if os(iOS) || os(visionOS)\n', '#endif\n'
    assert transport.startswith(prefix) and transport.endswith(suffix)
    transport_body = transport[len(prefix):-len(suffix)].replace('import StreamProtocol\n', '')
    pure = [write('pure', path.name, flat(path)) for path in sorted((root / 'Sources/StreamProtocol').glob('*.swift'))]
    pure += [write('pure', 'MacAudioRouteSession.swift', flat(root / 'iOSClient/MacAudioRouteSession.swift')),
             write('pure', 'main.swift', (here / 'shared/main.swift').read_text())]
    common = [('AudioRouting.swift', flat(root / 'Sources/StreamProtocol/AudioRouting.swift')),
              ('StreamMessage.swift', flat(root / 'Sources/StreamProtocol/StreamMessage.swift')),
              ('SessionLink.swift', (root / 'iOSClient/SessionLink.swift').read_text()),
              ('MacAudioRouteTransport.swift', transport_body)]
    shared = [write('shared', name, text) for name, text in common]
    shared += [write('shared', 'main.swift', (here / 'shared/transport.swift').read_text())]
    standins, manifest = fixture(root)
    record['extractionSHA256'] = manifest
    record['fixtureAdaptations'] = ['Shared imports removed for flat-module compilation; shared transport platform guard unwrapped for macOS fixture.', 'Actual StreamClient factory receives only an injected deterministic clock. Actual adapter and modal methods are copied verbatim. Fake Network peer supplies inert byte recording.']
    native = [write('native', name, text) for name, text in common]
    native += [write('native', 'MacAudioRouteSession.swift', flat(root / 'iOSClient/MacAudioRouteSession.swift')),
               write('native', 'VisionMacAudioController.swift', flat(root / 'visionOSClient/VisionMacAudioController.swift')),
               write('native', 'VisionMacAudioStatus.swift', flat(root / 'visionOSClient/VisionMacAudioStatus.swift')),
               write('native', 'VisionMacAudioTransport.swift', flat(root / 'visionOSClient/VisionMacAudioTransport.swift')),
               write('native', 'Client.swift', standins), write('native', 'main.swift', (here / 'native.swift').read_text())]
    network = write('modules', 'Network.swift', (here / 'shared/Network.swift').read_text())
    record['emittedSHA256'] = emitted
    record['static'] = checks(root, include_baseline=False)
    if not all(record['static']['checks'].values()):
        raise RuntimeError('Static integration gate failed')
    if args.emit_only:
        record.update(exitCode=0, execution='emit-only; zero Swift compiler or runtime commands')
        (output / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
        print('Fixture preparation passed. No compilation or Swift runtime test.')
        return 0
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE='1')
    base = ['/usr/bin/xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', str(output / 'cache')]

    def run(command, label, limit=180):
        remaining = 720 - (time.monotonic() - started)
        if remaining <= 0:
            raise TimeoutError('720 second driver budget exhausted')
        child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                 env=env, start_new_session=True)
        try:
            log, _ = child.communicate(timeout=min(limit, remaining))
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            log, _ = child.communicate(timeout=5)
            raise TimeoutError(label)
        finally:
            record['commands'].append({'label': label, 'exitCode': child.returncode, 'reaped': child.poll() is not None})
        (output / (label + '.log')).write_text(log)
        if child.returncode:
            raise RuntimeError(label + '\n' + log[-8000:])
        return log

    try:
        run(base + list(map(str, pure)) + ['-o', str(output / 'pure')], 'pure-compile')
        log = run([str(output / 'pure')], 'pure-runtime', 30)
        record['assertions']['sharedPolicy'] = int(re.search(r'(\d+) Mac audio routing checks passed', log)[1])
        run(base + ['-parse-as-library', '-whole-module-optimization', '-emit-module', '-emit-object',
                   '-module-name', 'Network', str(network), '-emit-module-path', str(output / 'Network.swiftmodule'),
                   '-o', str(output / 'Network.o')], 'network-stub-compile')
        for label, sources, pattern in [('sharedTransport', shared, r'(\d+) Mac audio transport checks passed'),
                                        ('nativeIntegration', native, r'(\d+) Vision audio integration checks passed')]:
            exe = output / label
            run(base + ['-I', str(output)] + list(map(str, sources)) + [str(output / 'Network.o'), '-o', str(exe)], label + '-compile')
            log = run([str(exe)], label + '-runtime', 30)
            record['assertions'][label] = int(re.search(pattern, log)[1])
        if record['assertions']['sharedPolicy'] != 65 or record['assertions']['sharedTransport'] != 16:
            raise RuntimeError('Shared reference assertion counts drifted')
        record['exitCode'] = 0
    except Exception as error:
        record['error'] = str(error)
    finally:
        record['sourceUnchanged'] = all(hashlib.sha256((root / name).read_bytes()).hexdigest() == digest for name, digest in originals.items())
        if not record['sourceUnchanged']:
            record['exitCode'] = 2
        (output / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
        print('RESULT_JSON ' + json.dumps(record), flush=True)
    return record['exitCode']


if __name__ == '__main__':
    sys.exit(main())

import hashlib
import json
import os
import platform
import re
import signal
import subprocess
import sys
import time
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'microphone-uplink'))
from extract import fixture as host_fixture

def fixture(root):
    files, manifest = host_fixture(root)
    files.pop('Main.swift')
    here = root / 'Tests/checks/vision-microphone-pipeline'
    files['Network.swift'] = (here/'Network.swift').read_text()
    files['Main.swift'] = (here/'Main.swift').read_text()
    names = ['Sources/StreamProtocol/'+n+'.swift' for n in ['AudioPacket','HostSettings']]
    names += ['visionOSClient/'+n+'.swift' for n in ['VisionAudioBuffer','VisionAudioHardware','VisionMicrophoneCapture']]
    names += ['iOSClient/'+n+'.swift' for n in ['IPadMicrophonePCM','IPadMicrophoneCapture','IPadMicrophonePolicy','IPadMicrophoneFrameGate']]
    names += ['Tests/checks/vision-microphone-control/Client.swift']
    for name in names: files[name] = (root/name).read_text()
    name = 'visionOSClient/StreamClient+VisionMicrophone.swift'
    original = (root/name).read_text()
    anchor = '}, closeFrames: { frames.close(captureID: captureID) }'
    assert original.count(anchor) == 1
    files[name] = original.replace(anchor, '}, requestPermission: testPermission, closeFrames: { frames.close(captureID: captureID) }', 1)
    manifest['permissionBoundaryOriginal'] = hashlib.sha256(original.encode()).hexdigest()
    manifest.update({name: hashlib.sha256(text.encode()).hexdigest() for name,text in files.items()})
    return files, manifest
MUTANTS = [
    ('client-tail', 'iOSClient/IPadMicrophoneFrameGate.swift', 'for block in blocks {', 'for block in blocks.prefix(2) {', 'continuous actual client burst preserves ordered PCM'),
    ('ingress-one', 'Sources/SillHost/MicrophoneIngress.swift', 'private static let frameCapacity = 6', 'private static let frameCapacity = 1', 'continuous actual client burst preserves ordered PCM'),
    ('render-one', 'Sources/SillHost/HostMicrophoneGrant.swift', 'private static let packetCapacity = 6', 'private static let packetCapacity = 1', 'continuous actual client burst preserves ordered PCM'),
    ('drain-one', 'Dispatch.swift', 'for frame in frames where', 'for frame in frames.prefix(1) where', 'continuous actual client burst preserves ordered PCM'),
    ('egress-route', 'Dispatch.swift', 'client.route.encrypted, client.route.fingerprint != nil, connection.state == .ready', '!client.route.encrypted, client.route.fingerprint != nil, connection.state == .ready', 'actual host state enables actual client capture'),
    ('short-residence', 'Sources/SillHost/HostMicrophoneGrant.swift', 'static let maxQueueAge: UInt64 = 160_000_000', 'static let maxQueueAge: UInt64 = 140_000_000', 'actual queued packet remains valid at exact160ms boundary'),
]


def main():
    root, output = (Path(p).resolve() for p in sys.argv[1:3])
    if output == root or root in output.parents:
        raise SystemExit('OUTPUT must be outside ROOT')
    output.mkdir(parents=True, exist_ok=True)
    if (output / 'result.json').exists():
        raise SystemExit('Reconcile the previous result before reusing OUTPUT')
    started = time.monotonic()
    record = {'scope': 'Actual Vision capture/conversion/policy/framegate, authenticated host dispatch/receiver/render, shared inert Network/graph/permission/sink. No native IO/network/call proof',
              'commands': [], 'mutants': [], 'assertions': 0, 'exitCode': 2}
    source_hashes = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
                     for folder in ['Sources','iOSClient','visionOSClient','Tests/checks/microphone-uplink','Tests/checks/vision-microphone-control','Tests/checks/vision-microphone-pipeline']
                     for p in (root / folder).rglob('*') if p.is_file()}
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE='1', TMPDIR=str(output / 'tmp'))
    Path(env['TMPDIR']).mkdir(exist_ok=True)
    generated = output / 'generated'
    cache = output / 'cache'
    cache.mkdir(exist_ok=True)
    base = ['/usr/bin/xcrun', 'swiftc', '-target', platform.machine() + '-apple-macosx14.0', '-swift-version', '5', '-package-name', 'sill', '-D', 'VISION_MICROPHONE_CHECKS', '-module-cache-path', str(cache)]

    def run(command, label):
        remaining = 660 - (time.monotonic() - started)
        if remaining <= 0:
            raise TimeoutError('660 second budget exhausted')
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
        record['commands'].append({'label': label, 'argv': command, 'exitCode': child.returncode,
                                   'pid': child.pid, 'reaped': child.poll() is not None, 'timedOut': timed_out})
        if timed_out:
            raise TimeoutError(label + ': diagnostics saved before teardown')
        return child.returncode, log

    def compile_module(name, paths, label):
        return run(base + ['-parse-as-library', '-emit-module', '-emit-object', '-whole-module-optimization', '-module-name', name]
                   + paths + ['-emit-module-path', str(output / (name + '.swiftmodule')), '-o', str(output / (name + '.o'))], label)

    try:
        files, manifest = fixture(root)
        record['extractionSHA256'] = manifest
        for name, source in files.items():
            path = generated / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(source)
        protocol = [name for name in files if name.startswith('Sources/StreamProtocol/')]
        app = [name for name in files if name not in protocol and name != 'Network.swift']
        objects = [str(output / (name + '.o')) for name in ['Network', 'StreamProtocol']]
        for name, sources in [('Network', ['Network.swift']), ('StreamProtocol', protocol)]:
            code, log = compile_module(name, [str(generated / n) for n in sources], 'module-' + name)
            if code:
                raise RuntimeError(name + ' failed\n' + log)

        def compile_app(replacement=None, executable=None, label='baseline-compile'):
            paths = [str(replacement[1]) if replacement and n == replacement[0] else str(generated / n) for n in app]
            return run(base + ['-parse-as-library', '-I', str(output)] + paths + objects + ['-o', str(executable)], label)

        executable = output / 'check'
        code, log = compile_app(executable=executable)
        if code:
            raise RuntimeError('baseline compile failed\n' + log)
        code, log = run([str(executable)], 'baseline-runtime')
        match = re.search(r'^RESULT_ASSERTIONS (\d+)$', log, re.M)
        if code or not match:
            raise RuntimeError('baseline runtime failed\n' + log)
        record['assertions'] = int(match[1])
        for name, target, old, new, witness in MUTANTS:
            entry = {'name': name, 'witness': witness, 'anchorMatches': files[target].count(old), 'caught': False}
            record['mutants'].append(entry)
            if entry['anchorMatches'] != 1:
                continue
            variant = output / ('mutant-' + name)
            variant.mkdir()
            path = variant / Path(target).name
            path.write_text(files[target].replace(old, new, 1))
            if target in protocol:
                code, log = compile_module('StreamProtocol', [str(path) if n == target else str(generated / n) for n in protocol], name + '-module')
            else:
                code = 0
            if code == 0:
                code, log = compile_app((target, path), variant / 'check', name + '-compile')
            entry['compileExit'] = code
            if code == 0:
                code, log = run([str(variant / 'check')], name + '-runtime')
                entry['runtimeExit'] = code
                entry['caught'] = code != 0 and ('FAIL ' + witness) in log
            if not entry['caught']:
                entry['diagnostic'] = log[-12000:]
            if target in protocol:
                code, log = compile_module('StreamProtocol', [str(generated / n) for n in protocol], name + '-restore')
                if code:
                    raise RuntimeError('protocol restore failed\n' + log)
        record['mutationCount'] = len(MUTANTS)
        record['mutationsCaught'] = sum(m['caught'] for m in record['mutants'])
        record['exitCode'] = 0 if record['mutationsCaught'] == len(MUTANTS) else 1
    except Exception as error:
        record['error'] = str(error)
    finally:
        record['sourceSHA256'] = source_hashes
        record['sourceUnchanged'] = all((root / name).is_file() and hashlib.sha256((root / name).read_bytes()).hexdigest() == digest
                                        for name, digest in source_hashes.items())
        if not record['sourceUnchanged']:
            record['exitCode'] = 2
        record['seconds'] = time.monotonic() - started
        (output / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
        print('RESULT_JSON ' + json.dumps(record), flush=True)
    return record['exitCode']


if __name__ == '__main__':
    sys.exit(main())

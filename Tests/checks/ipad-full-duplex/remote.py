import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import uuid

raw = sys.stdin.buffer.read()
print('INPUT_SHA256 ' + hashlib.sha256(raw).hexdigest(), flush=True)
payload = json.loads(raw)
raw = None
record = {'scope': 'Independent route adapter/controller and fake-engine player checks. No device/audio engine/unit/network opened; not source-guard transfer.'}
disk = None
output = None
child = None
mount = None

def health():
    return {name: subprocess.run(command, capture_output=True, text=True, timeout=10).stdout.strip()
            for name, command in {'swap': ['/usr/sbin/sysctl', 'vm.swapusage'],
                                  'pressure': ['/usr/bin/memory_pressure', '-Q']}.items()}

def run(command, timeout):
    global child
    child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        stdout, _ = child.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(child.pid, signal.SIGTERM)
        try: stdout, _ = child.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            stdout, _ = child.communicate(timeout=5)
        raise RuntimeError('isolated child timeout: ' + stdout.decode(errors='replace')[-16000:])
    return child.returncode, stdout.decode(errors='replace')

record['before'] = health()
try:
    disk = subprocess.check_output(['/usr/bin/hdiutil', 'attach', '-nomount', 'ram://262144'], text=True).strip()
    if not re.fullmatch(r'/dev/disk[0-9]+', disk): raise RuntimeError('unexpected disk')
    volume = 'CCRMic' + uuid.uuid4().hex[:10]
    subprocess.run(['/usr/sbin/diskutil', 'eraseVolume', 'HFS+', volume, disk], check=True, capture_output=True, timeout=20)
    info = plistlib.loads(subprocess.check_output(['/usr/sbin/diskutil', 'info', '-plist', disk]))
    mount = Path(info['MountPoint'])
    if str(mount) != '/Volumes/' + volume or not 0 < int(info['TotalSize']) <= 135 * 1024 * 1024:
        raise RuntimeError('RAM identity mismatch')
    hashes = payload['hashes']
    for name, data in payload['source'].items():
        if Path(name).is_absolute() or '..' in Path(name).parts: raise RuntimeError('invalid file name')
        raw = base64.b64decode(data, validate=True)
        if hashlib.sha256(raw).hexdigest() != hashes[name]: raise RuntimeError('input hash mismatch')
        (mount / name).parent.mkdir(parents=True, exist_ok=True)
        (mount / name).write_bytes(raw)
    payload = None
    record['inputHashesMatched'] = True
    output = Path(tempfile.mkdtemp(prefix='ccr-mic-converter-', dir='/private/tmp'))
    record['checks'] = []
    def check(name, command, timeout=120):
        code, log = run(command, timeout)
        record['checks'].append({'name': name, 'exitCode': code, 'log': log})
        if code != 0: raise RuntimeError(name + ' failed')
    flags = ['-swift-version', '5', '-module-cache-path', str(output / 'cache')]
    protocol = sorted(str(p) for p in (mount / 'Sources/StreamProtocol').glob('*.swift'))
    check('protocol-compile', ['/usr/bin/xcrun', 'swiftc', '-emit-library', '-emit-module', '-module-name', 'StreamProtocol', *protocol,
        '-emit-module-path', str(output / 'StreamProtocol.swiftmodule'), '-o', str(output / 'libStreamProtocol.dylib'), *flags])
    link = ['-I', str(output), '-L', str(output), '-lStreamProtocol', '-Xlinker', '-rpath', '-Xlinker', str(output)]
    logger = (mount / 'iOSClient/IPadMicrophoneCapture.swift').read_text().split('/// Native capture only.')[0]
    a = logger.index('    static let shared =')
    b = logger.index('    let fileURL:', a)
    logger = logger[:a] + '    static let shared = IPadMicrophoneDiagnostics(fileURL: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("diagnostics.json"))\n' + logger[b:]
    (output / 'Diagnostics.swift').write_text(logger)
    adapter = (mount / 'iOSClient/StreamClient+AudioRoutes.swift').read_text().replace('#if os(iOS)', '#if true')
    adapter = adapter[:adapter.index('    @MainActor var audioRouteAppActive:')] + '}\n#endif\n'
    adapter = adapter.replace('import UIKit\n', '').replace('import AVFoundation\n', '')
    fixture = (mount / 'iOSClient/Tests/audio-routes/Standins.swift').read_text().replace('// EXTRACTED_ADAPTER', adapter)
    (output / 'Adapter.swift').write_text('import StreamProtocol\n' + fixture)
    check('route-compile', ['/usr/bin/xcrun', 'swiftc', '-parse-as-library', *flags, *link,
        *[str(mount / 'iOSClient' / name) for name in ['IPadAudioRoutePolicy.swift', 'IPadMicrophonePolicy.swift', 'IPadRemoteAudioController.swift']],
        str(output / 'Diagnostics.swift'), str(output / 'Adapter.swift'), str(mount / 'iOSClient/Tests/audio-routes/main.swift'), '-o', str(output / 'routes')])
    check('routes', [str(output / 'routes'), str(output)], 30)
    for name in ['fixture.py', 'player-fixture.py']:
        check(name, ['python3', '-B', str(mount / 'Tests/checks/iPad-remote-audio' / name), str(mount), str(output)], 20)
    check('playback-compile', ['/usr/bin/xcrun', 'swiftc', '-parse-as-library', *flags, *link,
        str(mount / 'iOSClient/IPadAudioAdmission.swift'), str(mount / 'iOSClient/IPadRemoteAudioController.swift'), str(output / 'Diagnostics.swift'),
        str(output / 'ClientFixture.swift'), str(output / 'PlaybackFixture.swift'),
        str(mount / 'Tests/checks/iPad-remote-audio/main.swift'), '-o', str(output / 'playback')])
    check('playback', [str(output / 'playback'), str(output)], 30)
    record['memorySourcesUnchanged'] = all(hashlib.sha256((mount / name).read_bytes()).hexdigest() == digest for name, digest in hashes.items())
    record['exitCode'] = 0 if record['memorySourcesUnchanged'] else 1
except Exception as error:
    record['exitCode'] = 2
    record['error'] = str(error)
finally:
    if child is not None and child.poll() is None:
        os.killpg(child.pid, signal.SIGKILL)
        child.wait()
    record['childrenReaped'] = child is None or child.poll() is not None
    if output:
        shutil.rmtree(output)
        record['outputRemoved'] = not output.exists()
    if disk:
        detached = subprocess.run(['/usr/bin/hdiutil', 'detach', disk], capture_output=True, text=True, timeout=20)
        record['detachCode'] = detached.returncode
        record['sourceRemoved'] = detached.returncode == 0 and mount is not None and not mount.exists()
    record['after'] = health()
print('RESULT_JSON ' + json.dumps(record), flush=True)
sys.exit(record['exitCode'])

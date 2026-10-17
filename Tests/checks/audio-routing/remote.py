"""Executed via mini heavy. Input sources live only on a uniquely owned volatile RAM volume."""
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
import time
import uuid

raw = sys.stdin.buffer.read()
print('INPUT_SHA256 ' + hashlib.sha256(raw).hexdigest(), flush=True)
payload = json.loads(raw)
raw = None
volume = 'CCRRoute' + uuid.uuid4().hex[:10]
disk = None
output = None
child = None
record = {'runnerPID': os.getpid(), 'commandExitCodes': [], 'healthDuring': []}

def health():
    values = {}
    for key, command in {
        'swap': ['/usr/sbin/sysctl', 'vm.swapusage'],
        'pressure': ['/usr/bin/memory_pressure', '-Q'],
        'orca': ['/usr/bin/pgrep', '-f', 'orca-server-1.4'],
        'avd': ['/usr/bin/pgrep', '-f', 'qemu-system-aarch64']
    }.items():
        result = subprocess.run(command, capture_output=True, text=True, timeout=10)
        values[key] = result.stdout.strip()
    return values

def run(command, timeout=300):
    global child
    print('COMMAND ' + json.dumps(command), flush=True)
    start = time.monotonic()
    next_health = start + 15
    with (output / 'command.log').open('wb') as log:
        child = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        while child.poll() is None:
            now = time.monotonic()
            if now - start > timeout:
                os.killpg(child.pid, signal.SIGTERM)
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait(timeout=5)
                break
            if now >= next_health:
                record['healthDuring'].append(health())
                next_health = now + 15
            time.sleep(0.5)
    print((output / 'command.log').read_text(errors='replace'), flush=True)
    record['commandExitCodes'].append(child.returncode)
    return child.returncode == 0

record['before'] = health()
try:
    collision = subprocess.run(['/usr/bin/pgrep', '-x', 'swift-frontend|swiftc|swift-build|clang|xcodebuild'], capture_output=True, text=True)
    if collision.returncode == 0:
        raise RuntimeError('compiler resource collision: ' + collision.stdout.strip())
    disk = subprocess.check_output(['/usr/bin/hdiutil', 'attach', '-nomount', 'ram://262144'], text=True).strip()
    if not re.fullmatch(r'/dev/disk[0-9]+', disk):
        raise RuntimeError('unexpected RAM disk identity')
    subprocess.run(['/usr/sbin/diskutil', 'eraseVolume', 'HFS+', volume, disk], check=True, stdout=subprocess.DEVNULL, timeout=20)
    info = plistlib.loads(subprocess.check_output(['/usr/sbin/diskutil', 'info', '-plist', disk]))
    mount = Path(info['MountPoint'])
    if info.get('VolumeName') != volume or str(mount) != '/Volumes/' + volume or not 0 < int(info['TotalSize']) <= 135 * 1024 * 1024:
        raise RuntimeError('RAM identity mismatch')
    package = mount / 'input'
    package.mkdir(mode=0o700)
    hashes = payload['hashes']
    for name, encoded in payload['source'].items():
        path = Path(name)
        if path.is_absolute() or '..' in path.parts:
            raise RuntimeError('invalid source path')
        data = base64.b64decode(encoded, validate=True)
        if hashlib.sha256(data).hexdigest() != hashes[name]:
            raise RuntimeError('source hash mismatch')
        target = package / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    host_compile = payload['hostCompile']
    microphone = payload.get('microphone', False)
    payload = None
    record['inputHashesMatched'] = True
    output = Path(tempfile.mkdtemp(prefix='ccr-audio-routing-output-', dir='/private/tmp'))
    flags = ['-module-cache-path', str(output / 'cache')]
    protocol = sorted(str(path) for path in (package / 'Sources/StreamProtocol').glob('*.swift'))
    ok = run(['/usr/bin/xcrun', 'swiftc', '-parse-as-library', '-emit-module', '-emit-library', '-module-name', 'StreamProtocol'] + protocol +
             ['-emit-module-path', str(output / 'StreamProtocol.swiftmodule'), '-o', str(output / 'libStreamProtocol.dylib')] + flags)
    if ok:
        ok = run(['/usr/bin/xcrun', 'swiftc', '-I', str(output), '-L', str(output), '-lStreamProtocol', '-Xlinker', '-rpath', '-Xlinker', str(output),
                  str(package / 'Sources/SillHost/AudioHardwareRoutes.swift'), str(package / 'Tests/checks/audio-routing/main.swift'),
                  str(package / 'Tests/checks/audio-routing/CoordinatorFixture.swift'), '-o', str(output / 'check')] + flags)
    if ok:
        ok = run([str(output / 'check')], timeout=30)
    record['policyPassed'] = ok
    if ok and microphone:
        ok = run(['python3', '-B', str(package / 'Tests/checks/microphone-uplink/run.py'),
                  str(package), str(output / 'microphone')], timeout=660)
        result_file = output / 'microphone/result.json'
        if result_file.exists():
            record['microphone'] = json.loads(result_file.read_text())
            for log in (output / 'microphone').glob('*.log'):
                text = log.read_text(errors='replace')
                if log.stem.startswith('baseline') and ('error:' in text or 'FAIL ' in text):
                    print('DIAGNOSTIC ' + log.name + '\n' + text[-16000:], flush=True)
        link = ['-I', str(output), '-L', str(output), '-lStreamProtocol', '-Xlinker', '-rpath', '-Xlinker', str(output)]
        checks = {
            'microphone-policy': ['iOSClient/IPadMicrophonePolicy.swift', 'Tests/checks/ipad-microphone-control/main.swift'],
            'microphone-gate': ['iOSClient/IPadMicrophoneCapture.swift', 'iOSClient/IPadMicrophonePCM.swift', 'iOSClient/IPadMicrophoneFrameGate.swift', 'Tests/checks/ipad-microphone-frame-gate/main.swift'],
            'audio-lease': ['iOSClient/IPadAudioLeaseState.swift', 'Tests/checks/ipad-audio-lease/main.swift'],
            'audio-cleanup': ['iOSClient/IPadAudioLeaseState.swift', 'iOSClient/IPadAudioLeaseCoordinator.swift', 'Tests/checks/ipad-audio-cleanup/main.swift']
        }
        adapter = (package / 'iOSClient/StreamClient+AudioRoutes.swift').read_text().replace('#if os(iOS)', '#if true')
        fixture = (package / 'iOSClient/Tests/audio-routes/Standins.swift').read_text().replace('// EXTRACTED_ADAPTER', adapter)
        adapter_path = output / 'AudioRoutesAdapter.swift'
        adapter_path.write_text('import StreamProtocol\n' + fixture)
        adapter_test = output / 'audio-route-adapter-test/main.swift'
        adapter_test.parent.mkdir()
        adapter_test.write_text('import StreamProtocol\n' + (package / 'iOSClient/Tests/audio-routes/main.swift').read_text())
        checks['audio-route-adapter'] = ['iOSClient/IPadMicrophonePolicy.swift', 'iOSClient/IPadAudioRoutePolicy.swift',
            'iOSClient/IPadRemoteAudioController.swift', str(adapter_path), str(adapter_test)]
        record['iPadChecks'] = {}
        for name, paths in checks.items():
            if not ok: break
            executable = output / name
            ok = run(['/usr/bin/xcrun', 'swiftc'] + link + [str(package / path) for path in paths] + ['-o', str(executable)] + flags)
            if ok: ok = run([str(executable)], timeout=30)
            record['iPadChecks'][name] = ok
    if ok and host_compile:
        record['hostCompilePassed'] = run(['/usr/bin/xcrun', 'swift', 'build', '--package-path', str(package),
            '--scratch-path', str(output / 'host-build'), '--target', 'SillMenuBar' if microphone else 'SillHostCore', '--jobs', '1'], timeout=420)
        ok = record['hostCompilePassed']
    record['memorySourcesUnchanged'] = all(hashlib.sha256((package / name).read_bytes()).hexdigest() == value for name, value in hashes.items())
    record['exitCode'] = 0 if ok and record['memorySourcesUnchanged'] else 1
except Exception as error:
    record['error'] = type(error).__name__ + ': ' + str(error)
    record['exitCode'] = 2
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
        record['sourceRemoved'] = detached.returncode == 0 and not Path('/Volumes', volume).exists()
    record['after'] = health()
print('RESULT_JSON ' + json.dumps(record), flush=True)
sys.exit(record['exitCode'])

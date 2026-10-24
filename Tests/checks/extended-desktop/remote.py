"""Mini runner. Source, compiler cache and executable remain on one owned RAM volume."""
import base64
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
import uuid

raw = sys.stdin.buffer.read()
print('INPUT_SHA256 ' + hashlib.sha256(raw).hexdigest(), flush=True)
payload = json.loads(raw)
raw = None
volume = 'CCRExt' + uuid.uuid4().hex[:10]
disk = None
mount = None
child = None
record = {'scope': 'pure host policy and lifecycle; no AppKit/private display execution', 'commands': []}


def health():
    result = {}
    for name, command in {
        'swap': ['/usr/sbin/sysctl', 'vm.swapusage'],
        'pressure': ['/usr/bin/memory_pressure', '-Q'],
        'orca': ['/usr/bin/pgrep', '-f', 'orca-server-1.4'],
        'avd': ['/usr/bin/pgrep', '-f', 'qemu-system-aarch64'],
    }.items():
        try:
            process = subprocess.run(command, capture_output=True, text=True, timeout=10)
            result[name] = {'exitCode': process.returncode, 'stdout': process.stdout.strip(), 'stderr': process.stderr.strip()}
        except OSError as error:
            result[name] = {'error': str(error)}
    return result


def run(command, timeout):
    global child
    print('COMMAND ' + json.dumps(command), flush=True)
    with (mount / 'command.log').open('wb') as log:
        child = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True, env=environment)
        start = time.monotonic()
        sampled = False
        while child.poll() is None:
            if time.monotonic() - start > timeout:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait(timeout=5)
                break
            if not sampled and time.monotonic() - start > 10:
                record['during'] = health()
                sampled = True
            time.sleep(0.1)
    print((mount / 'command.log').read_text(errors='replace'), flush=True)
    record['commands'].append({'exitCode': child.returncode, 'command': command})
    return child.returncode == 0


record['before'] = health()
try:
    disk = subprocess.check_output(['/usr/bin/hdiutil', 'attach', '-nomount', 'ram://262144'], text=True).strip()
    if not re.fullmatch(r'/dev/disk[0-9]+', disk):
        raise RuntimeError('unexpected RAM disk identity')
    subprocess.run(['/usr/sbin/diskutil', 'eraseVolume', 'HFS+', volume, disk], check=True, stdout=subprocess.DEVNULL, timeout=20)
    info = plistlib.loads(subprocess.check_output(['/usr/sbin/diskutil', 'info', '-plist', disk]))
    mount = Path(info['MountPoint'])
    if info.get('VolumeName') != volume or str(mount) != '/Volumes/' + volume or not 0 < int(info['TotalSize']) <= 135 * 1024 * 1024:
        raise RuntimeError('RAM volume verification failed')
    hashes = payload['hashes']
    for name, encoded in payload['sources'].items():
        if Path(name).name != name or not name.endswith('.swift'):
            raise RuntimeError('unexpected input name')
        data = base64.b64decode(encoded, validate=True)
        if hashlib.sha256(data).hexdigest() != hashes[name]:
            raise RuntimeError('input hash mismatch')
        (mount / name).write_bytes(data)
    payload = None
    record['inputHashesMatched'] = True
    environment = dict(os.environ, TMPDIR=str(mount))
    command = ['/usr/bin/xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(mount / 'cache')]
    command += [str(mount / name) for name in hashes]
    command += ['-o', str(mount / 'checks')]
    ok = run(command, timeout=100)
    if ok:
        ok = run([str(mount / 'checks')], timeout=20)
    record['memoryInputUnchanged'] = all(hashlib.sha256((mount / name).read_bytes()).hexdigest() == digest for name, digest in hashes.items())
    record['exitCode'] = 0 if ok and record['memoryInputUnchanged'] else 1
except Exception as error:
    record['error'] = type(error).__name__ + ': ' + str(error)
    record['exitCode'] = 2
finally:
    if child is not None and child.poll() is None:
        os.killpg(child.pid, signal.SIGKILL)
        child.wait(timeout=5)
    record['childrenReaped'] = child is None or child.poll() is not None
    if disk:
        detached = subprocess.run(['/usr/bin/hdiutil', 'detach', disk], capture_output=True, text=True, timeout=20)
        record['sourceRemoved'] = detached.returncode == 0 and not Path('/Volumes', volume).exists()
        record['detachCode'] = detached.returncode
    record['after'] = health()
print('RESULT_JSON ' + json.dumps(record), flush=True)
sys.exit(record['exitCode'])

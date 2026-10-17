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
record = {'scope': 'Independent synthetic keyboard proposal and production coordinate geometry; no application/window/device launched. Not SwiftUI keyboard runtime or source-guard transfer.'}
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
    volume = 'CCRKeys' + uuid.uuid4().hex[:10]
    subprocess.run(['/usr/sbin/diskutil', 'eraseVolume', 'HFS+', volume, disk], check=True, capture_output=True, timeout=20)
    info = plistlib.loads(subprocess.check_output(['/usr/sbin/diskutil', 'info', '-plist', disk]))
    mount = Path(info['MountPoint'])
    if str(mount) != '/Volumes/' + volume or not 0 < int(info['TotalSize']) <= 135 * 1024 * 1024:
        raise RuntimeError('RAM identity mismatch')
    source = base64.b64decode(payload['source'], validate=True)
    digest = payload['sha256']
    if hashlib.sha256(source).hexdigest() != digest: raise RuntimeError('input hash mismatch')
    (mount / 'main.swift').write_bytes(source)
    payload = None
    record['inputHashesMatched'] = True
    output = Path(tempfile.mkdtemp(prefix='ccr-keyboard-geometry-', dir='/private/tmp'))
    record['compileExit'], record['compileLog'] = run(['/usr/bin/xcrun', 'swiftc', '-module-cache-path',
        str(output / 'cache'), str(mount / 'main.swift'), '-o', str(output / 'check')], 120)
    if record['compileExit'] == 0:
        record['runtimeExit'], record['runtimeLog'] = run([str(output / 'check')], 20)
    record['memorySourcesUnchanged'] = hashlib.sha256((mount / 'main.swift').read_bytes()).hexdigest() == digest
    record['exitCode'] = 0 if record['compileExit'] == 0 and record.get('runtimeExit') == 0 and record['memorySourcesUnchanged'] else 1
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

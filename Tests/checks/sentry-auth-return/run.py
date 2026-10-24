#!/usr/bin/env python3
"""Execute exact return boundaries with inert participants and declined authentication."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[3]
here = Path(__file__).resolve().parent
challenge = '--challenge' in sys.argv
paths = [root / name for name in [
    'Sources/StreamProtocol/AudioPrivacy.swift',
    'Sources/SillHost/LocalAudioReturn.swift',
    'Sources/SillHost/LocalAudioParticipants.swift',
    'Sources/SillHost/HostAudioPrivacyModel.swift',
]] + [here / ('ChallengeChecks.swift' if challenge else 'Checks.swift'), Path(__file__).resolve()]
before = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
local = paths[1].read_text()
start, end = local.index('@MainActor\nfinal class LocalAudioAuthentication'), local.index('@MainActor\nfinal class LocalAudioJournal')
local = (local if challenge else local[:start] + local[end:]).replace('import LocalAuthentication\n', '')
if challenge:
    assert local.count('Task.sleep(for: .seconds(45))') == 1
    local = local.replace('Task.sleep(for: .seconds(45))', 'Task.sleep(for: .milliseconds(50))')
participants = paths[2].read_text()
program = '\n'.join([paths[0].read_text(), local, participants,
    paths[3].read_text().replace('import StreamProtocol\n', ''), paths[4].read_text()])
flags = ['-D', 'RECOVERY'] if 'func recoverClosedLocalReturn(' in participants else []
runner = '''import hashlib,subprocess,sys
source=sys.stdin.buffer.read()
print('received_sha256='+hashlib.sha256(source).hexdigest(),flush=True)
result=subprocess.run(['/usr/bin/swift','-swift-version','5','-package-name','Sill',*sys.argv[1:],'-'],input=source,timeout=120)
del source
print('RAM input released; no source checkout',flush=True)
raise SystemExit(result.returncode)
'''
print('sent_sha256='+hashlib.sha256(program.encode()).hexdigest(), flush=True)
command = ['python3', '-B', '-c', runner, *flags]
if '--local' not in sys.argv:
    command = ['/Users/ambrion/.local/bin/mini', 'run', '--cwd', '/Users/sin-wonho', '--', *command]
result = subprocess.run(command, input=program, text=True, timeout=160)
after = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
print(json.dumps({'sourceSHA256': before, 'sourceUnchanged': before == after,
    'authenticationBoundary': 'inert LAContext; expiry shortened to 50 ms' if challenge else 'authentication class excluded',
    'actualAuthenticationHALUIJournalDeviceActions': 0, 'exitCode': result.returncode}), flush=True)
sys.exit(result.returncode if before == after else 2)

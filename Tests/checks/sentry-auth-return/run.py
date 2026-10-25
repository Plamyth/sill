#!/usr/bin/env python3
"""Execute exact return boundaries with inert participants and declined authentication."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[3]
here = Path(__file__).resolve().parent
system_context = '--system-context' in sys.argv
challenge = '--challenge' in sys.argv or system_context
legacy = '--legacy-context' in sys.argv
paths = [root / name for name in [
    'Sources/StreamProtocol/AudioPrivacy.swift',
    'Sources/SillHost/LocalAudioReturn.swift',
    'Sources/SillHost/LocalAudioParticipants.swift',
    'Sources/SillHost/HostAudioPrivacyModel.swift',
]] + [here / ('SystemContextChecks.swift' if system_context else 'ChallengeChecks.swift' if legacy else 'RightChecks.swift' if challenge else 'Checks.swift'), Path(__file__).resolve()]
before = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
local = paths[1].read_text()
evaluated_revision = 'working-tree'
if '--baseline' in sys.argv:
    evaluated_revision = '438569be69099b2d369d12ebc494be81cf3ae7da'
    local = subprocess.check_output(['git', 'show',
        '438569be69099b2d369d12ebc494be81cf3ae7da:Sources/SillHost/LocalAudioReturn.swift'], cwd=root, text=True)
elif '--right-layer-baseline' in sys.argv:
    evaluated_revision = '229c02613b341139981edbe280df0243553bc144'
    local = subprocess.check_output(['git', 'show',
        '229c02613b341139981edbe280df0243553bc144:Sources/SillHost/LocalAudioReturn.swift'], cwd=root, text=True)
elif system_context:
    evaluated_revision = '4af9d14db8bbbc7392d9f25b108cd8e2f3358a8b'
    local = subprocess.check_output(['git', 'show',
        evaluated_revision + ':Sources/SillHost/LocalAudioReturn.swift'], cwd=root, text=True)
elif legacy:
    evaluated_revision = '8c6e1d90dbc3c75dfcb682a12b9fa9d9f1e7d6e7'
    local = subprocess.check_output(['git', 'show',
        '8c6e1d90dbc3c75dfcb682a12b9fa9d9f1e7d6e7:Sources/SillHost/LocalAudioReturn.swift'], cwd=root, text=True)
authentication_hash = hashlib.sha256(local.encode()).hexdigest()
start, end = local.index('@MainActor\nfinal class LocalAudioAuthentication'), local.index('@MainActor\nfinal class LocalAudioJournal')
local = (local if challenge else local[:start] + local[end:]).replace('import LocalAuthentication\n', '').replace('import LocalAuthenticationEmbeddedUI\n', '')
if challenge:
    assert local.count('Task.sleep(for: .milliseconds(Self.maximumWaitMilliseconds))') == 1
    assert 'static let maximumWaitMilliseconds = 120_000' in local
    local = local.replace('static let maximumWaitMilliseconds = 120_000', 'static let maximumWaitMilliseconds = 200')
if '--unanchored-mutant' in sys.argv:
    anchor = ',\n                                          in: window)'
    assert local.count(anchor) == 1
    local = local.replace(anchor, ')')
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
    'evaluatedAuthenticationSHA256': authentication_hash,
    'evaluatedRevision': evaluated_revision,
    'unanchoredMutant': '--unanchored-mutant' in sys.argv,
    'authenticationBoundary': ('inert LAContext' if legacy or system_context else 'inert LARight and NSWindow') + '; expiry shortened to 200 ms' if challenge else 'authentication class excluded',
    'actualAuthenticationHALUIJournalDeviceActions': 0, 'exitCode': result.returncode}), flush=True)
sys.exit(result.returncode if before == after else 2)

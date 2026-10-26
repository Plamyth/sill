"""실제 Sentry 소비자 세대 전환을 Mini 휘발성 입력으로 검사한다."""
import ast
import base64
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / 'Tests/checks'))
from swift_platform import select_platform

label = sys.argv[1]
route = json.loads(subprocess.check_output(['/Users/ambrion/.local/bin/storage-route', 'path',
    'development-archive', '--project', 'BT_CCR-ipad', '--filename', 'sentry-generation-retirement-20261026-' + label], text=True))
OUT = Path(route['path'])
OUT.mkdir(parents=True, exist_ok=True)
assert not (OUT / (label + '.json')).exists(), '같은 검사 영수증을 먼저 대조하세요.'

def block(source, marker):
    start = source.index(marker)
    opening = source.index('{', start)
    depth = 1
    for end in range(opening + 1, len(source)):
        depth += (source[end] == '{') - (source[end] == '}')
        if depth == 0:
            return source[start:end + 1]
    raise AssertionError(marker)

sha = lambda data: hashlib.sha256(data).hexdigest()
paths = list((ROOT / 'Sources/StreamProtocol').glob('*.swift'))
paths += [ROOT / 'iOSClient' / name for name in ['IPadSentryControl.swift', 'IPadSentryObservation.swift',
    'StreamClient+Sentry.swift', 'StreamClient.swift', 'MessageReader.swift']]
paths += [HERE / name for name in ['Standins.swift', 'main.swift', 'generation.py']]
paths += [ROOT / 'Tests/checks/sentry-control-v2/fixtures.json']
original = {str(p.relative_to(ROOT)): sha(p.read_bytes()) for p in paths}
files = {str(p.relative_to(ROOT)): p.read_bytes() for p in paths if p.suffix == '.swift'}
ios = select_platform((ROOT / 'iOSClient/StreamClient.swift').read_text(), vision=False, ios=True)
files['Standins.swift'] = (HERE / 'Standins.swift').read_text().replace('// ACCEPT_REPLY', block(ios, 'func acceptIPadSentryReply(')).encode()
files['Wiring.swift'] = select_platform((ROOT / 'iOSClient/StreamClient+Sentry.swift').read_text(), vision=False, ios=True).replace('import Network\n', '').encode()
files['Reader.swift'] = (ROOT / 'iOSClient/MessageReader.swift').read_bytes().replace(b'import Network\n', b'')
if '--baseline' in sys.argv:
    files['iOSClient/IPadSentryControl.swift'] = subprocess.check_output(['git','show','21235fc:iOSClient/IPadSentryControl.swift'],cwd=ROOT)
files['Legacy.swift'] = subprocess.check_output(['git','show','21235fc:iOSClient/IPadSentryControl.swift'],cwd=ROOT).replace(b'IPadSentryControl',b'LegacySentryControl')
files['fixture.json'] = (ROOT / 'Tests/checks/sentry-control-v2/fixtures.json').read_bytes()
runner_tree = ast.parse((ROOT / 'Tests/checks/reconnect-glue/mini.py').read_text())
runner = next(ast.literal_eval(n.value) for n in runner_tree.body if isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'runner' for t in n.targets))
a = runner.index(' sources='); b = runner.index(" record['commandExitCodes']=[]", a)
runner = runner[:a] + '''
 flags=['-swift-version','5','-module-cache-path',cache]
 protocol=sorted(str(p) for p in (package/'Sources/StreamProtocol').glob('*.swift'))
 commands=[['/usr/bin/xcrun','swiftc',*flags,'-emit-module','-emit-object','-whole-module-optimization','-module-name','StreamProtocol',*protocol,'-emit-module-path',str(output/'StreamProtocol.swiftmodule'),'-o',str(output/'StreamProtocol.o')],
 ['/usr/bin/xcrun','swiftc',*flags,'-I',str(output),str(package/'iOSClient/IPadSentryObservation.swift'),str(package/'iOSClient/IPadSentryControl.swift'),str(package/'Legacy.swift'),str(package/'Standins.swift'),str(package/'Wiring.swift'),str(package/'Reader.swift'),str(package/'Tests/checks/ipad-sentry-observation/main.swift'),str(output/'StreamProtocol.o'),'-o',str(output/'consumer')],
 [str(output/'consumer'),str(package/'fixture.json')]]
''' + runner[b:]
runner = runner.replace('CCRReconnect', 'CCRSentry').replace('ccr-reconnect-output-', 'ccr-sentry-output-')
emitted = {name: sha(data) for name, data in files.items()}
payload = json.dumps({'source': {name: base64.b64encode(data).decode() for name, data in files.items()}, 'hashes': emitted}).encode()
process = subprocess.run(['/Users/ambrion/.local/bin/mini', 'heavy', '--cwd', '/private/tmp', '--', 'python3', '-B', '-c', runner], input=payload, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=600)
(OUT / (label + '.log')).write_bytes(process.stdout)
lines = process.stdout.decode(errors='replace').splitlines()
records = [line[len('RESULT_JSON '):] for line in lines if line.startswith('RESULT_JSON ')]
remote = json.loads(records[-1]) if records else None
record = dict(baselineProduct='--baseline' in sys.argv, exitCode=process.returncode, sourceHEAD=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
    sourceSHA256=original, emittedSHA256=emitted, inputSHA256=sha(payload),
    sourceUnchanged=all(sha((ROOT / name).read_bytes()) == value for name, value in original.items()),
    inputHashMatched=('INPUT_SHA256 ' + sha(payload)) in lines, remote=remote,
    checks=sum(line.startswith('PASS ') for line in lines), deviceHostAudioPermissionEffects=0,
    scope='실제 소비자와 reader; TLS/기기/네트워크는 메모리 대역. Mini 작업 이전 수용과 실기기 검증은 별도.')
(OUT / (label + '.json')).write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n')
print('\n'.join(lines[-16:]))
print(json.dumps({k:v for k,v in record.items() if k not in ['sourceSHA256','emittedSHA256']},ensure_ascii=False))
sys.exit(0 if process.returncode == 0 and record['sourceUnchanged'] and record['inputHashMatched'] and remote and remote.get('sourceRemoved') and remote.get('outputRemoved') and remote.get('memorySourcesUnchanged') else 1)

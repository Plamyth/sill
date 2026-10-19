import base64, hashlib, json, subprocess, sys
from pathlib import Path
from extract import ROOT, fixture
label=sys.argv[1]
out=ROOT/'.build/checks/vision-input-controls/receipts';out.mkdir(parents=True,exist_ok=True)
if (out/(label+'.json')).exists(): raise SystemExit('Reconcile prior attempt')
files,extraction=fixture()
sha=lambda b:hashlib.sha256(b).hexdigest()
paths=['iOSClient/StreamClient.swift','iOSClient/SessionLink.swift','iOSClient/InputOverlay.swift','iOSClient/KeyChords.swift','Sources/SillHost/KeyStrokes.swift','Sources/SillHost/SourceInputFence.swift','visionOSClient/VisionPresentation.swift','visionOSClient/SillVisionApp.swift','visionOSClient/VisionSpatialInput.swift','visionOSClient/VisionPointer.swift','visionOSClient/VisionInputSession.swift','visionOSClient/VisionInputDebt.swift','visionOSClient/VisionRemoteKey.swift','Tests/checks/vision-input-controls/SourceInputFence.swift']
paths += [str(p.relative_to(ROOT)) for p in sorted((ROOT/'Sources/StreamProtocol').glob('*.swift'))]
original={n:sha((ROOT/n).read_bytes()) for n in paths}
payload=json.dumps({'source':{n:base64.b64encode(t.encode()).decode() for n,t in files.items()},'hashes':{n:sha(t.encode()) for n,t in files.items()}}).encode()
runner=(Path(__file__).parent/'remote.py').read_text()
process = subprocess.Popen(['/Users/ambrion/.local/bin/mini', 'heavy', '--cwd', '/private/tmp', '--', 'python3', '-B', '-c', runner], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
try:
    log, _ = process.communicate(payload, timeout=600)
except subprocess.TimeoutExpired:
    process.terminate()
    log, _ = process.communicate(timeout=30)
(out / (label + '.log')).write_bytes(log)
records = [line[len('RESULT_JSON '):] for line in log.decode(errors='replace').splitlines() if line.startswith('RESULT_JSON ')]
record = {'exitCode': process.returncode, 'transportPID': process.pid, 'transportReaped': process.poll() is not None, 'sourceHEAD': subprocess.check_output(['git', '--no-lazy-fetch', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(), 'scope': 'Independent RAM input validation, not codex-source-guard transfer acceptance', 'inputSHA256': sha(payload), 'remoteInputHashMatched': ('INPUT_SHA256 ' + sha(payload)).encode() in log, 'sourceSHA256': original, 'sourceUnchanged': all(sha((ROOT / n).read_bytes()) == h for n, h in original.items()), 'extractionSHA256': extraction, 'remoteResult': json.loads(records[-1]) if records else None}
(out / (label + '.json')).write_text(json.dumps(record, indent=2) + '\n')
print(log.decode(errors='replace'))
print(json.dumps(record, indent=2))
sys.exit(process.returncode)

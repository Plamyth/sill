import argparse
import base64
import hashlib
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--output', required=True)
args = parser.parse_args()
out = Path(args.output)
if not out.is_absolute() or out.exists(): raise SystemExit('fresh routed output required')
out.mkdir()
here = Path(__file__).resolve().parent
root = here.parents[2]
source = root / 'iOSClient/StreamClient.swift'
text = source.read_text()
def block(text, signature):
    start = text.index(signature)
    end = text.index('{', start) + 1
    depth = 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]
methods = '\n'.join(block(text,s) for s in ['func select(_ source:', 'func selectDisplay(', 'private func request(', 'func launch(bundleID:'])
client = (here/'Client.swift').read_text().replace('// CLIENT_METHODS', methods)
client = client.replace('// RESUME_SOURCE',block(text,'if let resume = self.resumeSource'))
inputs = {p.name:p.read_text() for p in (root/'Sources/StreamProtocol').glob('*.swift')}
inputs['Client.swift'] = client
inputs['main.swift'] = (here/'main.swift').read_text()
sha = lambda data: hashlib.sha256(data).hexdigest()
hashes = {name:sha(value.encode()) for name,value in inputs.items()}
payload = json.dumps({'sources':{name:base64.b64encode(value.encode()).decode() for name,value in inputs.items()},'hashes':hashes}).encode()
runner = (here.parent/'extended-desktop/remote.py').read_text()
start = runner.index('    collision = subprocess.run(')
end = runner.index('    disk = subprocess.check_output(',start)
runner = runner[:start] + runner[end:]
paths = [source] + list(here.glob('*.*')) + list((root/'Sources/StreamProtocol').glob('*.swift'))
before = {str(p.relative_to(root)):sha(p.read_bytes()) for p in paths}
p = subprocess.run(['/Users/ambrion/.local/bin/mini','heavy','--cwd','/private/tmp','--','python3','-B','-c',runner],input=payload,capture_output=True,timeout=240)
log = p.stdout.decode(errors='replace')
(out/'run.log').write_text(log)
records = [json.loads(line[12:]) for line in log.splitlines() if line.startswith('RESULT_JSON ')]
receipt = {'scope':'actual client entry/request/resume methods; controlled catalog/transport/audio boundaries in Mini RAM; not full UIKit or sourceguard transfer acceptance','head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),'sourceHashes':before,'sourceUnchanged':all(sha(p.read_bytes()) == before[str(p.relative_to(root))] for p in paths),'transportHashMatched':'INPUT_SHA256 '+sha(payload) in log,'inputHashes':hashes,'remote':records[-1] if records else None,'exit':p.returncode}
(out/'result.json').write_text(json.dumps(receipt,indent=2)+'\n')
print(log)
print('RECEIPT '+str(out/'result.json'))
remote = receipt['remote'] or {}
verified = receipt['sourceUnchanged'] and receipt['transportHashMatched'] and all(remote.get(key) for key in ['inputHashesMatched','memoryInputUnchanged','childrenReaped','sourceRemoved'])
raise SystemExit(p.returncode or (0 if verified and remote.get('exitCode') == 0 else 2))

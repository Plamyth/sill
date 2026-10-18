#!/usr/bin/env python3
import argparse
import base64
import hashlib
import json
from pathlib import Path
import subprocess

parser=argparse.ArgumentParser()
parser.add_argument('--output',required=True)
args=parser.parse_args()
out=Path(args.output)
if not out.is_absolute() or out.exists(): raise SystemExit('fresh routed output path required')
out.mkdir()
here=Path(__file__).resolve().parent
root=here.parents[2]
source=root/'Sources/SillHost/ExtendedDesktop.swift'
text=source.read_text()
start=text.index('private static func valid(')
brace=text.index('{',start)
end=brace+1
depth=1
while depth:
    depth+=(text[end]=='{')-(text[end]=='}')
    end+=1
adapter=text[start:end].replace('private static func','static func',1)
# Only CG boundary symbols are remapped; the extracted production algorithm is unchanged.
for name in ['CGDisplayIsActive','CGDisplayMirrorsDisplay','CGDisplayIsInMirrorSet','CGDisplayCopyDisplayMode','CGDisplayBounds','kCGNullDirectDisplay']:
    adapter=adapter.replace(name,'fixture'+name)
fixture=(here/'Fixtures.swift').read_text().replace('// VALID_ADAPTER',adapter)
inputs={'Fixtures.swift':fixture,'main.swift':(here/'main.swift').read_text()}
sha=lambda b:hashlib.sha256(b).hexdigest()
hashes={k:sha(v.encode()) for k,v in inputs.items()}
payload=json.dumps({'sources':{k:base64.b64encode(v.encode()).decode() for k,v in inputs.items()},'hashes':hashes}).encode()
runner=(here.parent/'extended-desktop/remote.py').read_text()
start=runner.index("    collision = subprocess.run(")
end=runner.index("    disk = subprocess.check_output(",start)
runner=runner[:start]+runner[end:]
before=sha(source.read_bytes())
proc=subprocess.run(['/Users/ambrion/.local/bin/mini','heavy','--cwd','/private/tmp','--','python3','-B','-c',runner],input=payload,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=240)
log=proc.stdout.decode(errors='replace')
(out/'run.log').write_text(log)
records=[json.loads(l.removeprefix('RESULT_JSON ')) for l in log.splitlines() if l.startswith('RESULT_JSON ')]
receipt={'scope':'actual valid adapter under controlled CG answers in volatile Mini RAM; not native macOS UI/Pencil/sourceguard transfer acceptance','head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),'sourceSHA256':before,'sourceUnchanged':sha(source.read_bytes())==before,'inputHashes':hashes,'transportHashMatched':'INPUT_SHA256 '+sha(payload) in log,'remote':records[-1] if records else None,'exit':proc.returncode}
(out/'result.json').write_text(json.dumps(receipt,indent=2)+'\n')
print(log)
print('RECEIPT '+str(out/'result.json'))
raise SystemExit(proc.returncode)

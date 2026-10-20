import base64
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[3]
paths = [ROOT / "Sources/SillHost/LocalAudioRelayMachO.swift", Path(__file__).with_name("main.swift")]
source = b"\n".join(path.read_bytes() for path in paths)
before = {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}
images = []
for path in [Path("/opt/homebrew/bin/node").resolve(), Path("/Library/Frameworks/Python.framework/Versions/3.13/Resources/Python.app/Contents/MacOS/Python")]:
    text = subprocess.check_output(["/usr/bin/otool", "-l", str(path)], text=True)
    loads = re.findall(r"\bcmd LC_(?:LOAD_DYLIB|LOAD_WEAK_DYLIB|REEXPORT_DYLIB|LAZY_LOAD_DYLIB|LOAD_UPWARD_DYLIB)\n\s+cmdsize \d+\n\s+name (.*?) \(offset", text)
    rpaths = re.findall(r"\bcmd LC_RPATH\n\s+cmdsize \d+\n\s+path (.*?) \(offset", text)
    images.append({"data": base64.b64encode(path.read_bytes()).decode(), "loads": sorted(set(loads)), "rpaths": sorted(set(rpaths))})
runner = r'''
import base64,hashlib,json,shutil,subprocess,sys,tempfile
p=json.load(sys.stdin);source=base64.b64decode(p['source']);out=tempfile.mkdtemp(prefix='ccr-relay-macho-');code=2
try:
 r=subprocess.run(['/usr/bin/xcrun','swiftc','-swift-version','5','-module-cache-path',out+'/cache','-','-o',out+'/check'],input=source,timeout=180)
 if r.returncode==0:r=subprocess.run([out+'/check'],input=json.dumps(p['images']).encode(),timeout=30)
 code=r.returncode
finally:
 shutil.rmtree(out);print('RECEIPT '+json.dumps({'exitCode':code,'sourceSHA256':hashlib.sha256(source).hexdigest(),'outputRemoved':not __import__('os').path.exists(out)}),flush=True)
sys.exit(code)
'''
payload = json.dumps({"source": base64.b64encode(source).decode(), "images": images}).encode()
result = subprocess.run([str(Path.home() / ".local/bin/mini"), "run", "--cwd", "/tmp", "--", "python3", "-c", runner], input=payload, capture_output=True, timeout=300)
print(result.stdout.decode(), end="")
print(result.stderr.decode(), end="")
records = [json.loads(line[8:]) for line in result.stdout.decode().splitlines() if line.startswith("RECEIPT ")]
assert result.returncode == 0 and records[-1]["outputRemoved"]
assert records[-1]["sourceSHA256"] == hashlib.sha256(source).hexdigest()
assert all(hashlib.sha256(Path(path).read_bytes()).hexdigest() == digest for path, digest in before.items())

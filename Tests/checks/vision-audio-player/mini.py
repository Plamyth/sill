import base64
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent / 'receipts'
OUT.mkdir(exist_ok=True)
attempt = sys.argv[1]
if attempt not in ('01-red', '02-red', '03-green') or (OUT / (attempt + '.json')).exists():
    raise SystemExit('one run and two diagnostic corrections maximum; never replace a receipt')
sha = lambda data: hashlib.sha256(data).hexdigest()
names = ['visionOSClient/VisionAudioBuffer.swift', 'Tests/checks/vision-audio-player/main.swift']
if (ROOT / 'visionOSClient/VisionAudioPlayer.swift').exists():
    names.append('visionOSClient/VisionAudioPlayer.swift')
sources = {name: (ROOT / name).read_bytes() for name in names}
hashes = {name: sha(data) for name, data in sources.items()}
payload = json.dumps({'source': {name: base64.b64encode(data).decode() for name, data in sources.items()}, 'hashes': hashes}).encode()
runner = r'''
import base64,hashlib,json,os,pathlib,plistlib,re,signal,subprocess,sys,tempfile,uuid,shutil
raw=sys.stdin.buffer.read();print('INPUT_SHA256 '+hashlib.sha256(raw).hexdigest(),flush=True);p=json.loads(raw);raw=None
volume='CCRAudio'+uuid.uuid4().hex[:10];disk=None;output=None;child=None;record={'runnerPID':os.getpid(),'childPIDs':[]}
def health():
 result={}
 commands={'swap':['/usr/sbin/sysctl','vm.swapusage'],'pressure':['/usr/bin/memory_pressure','-Q'],'orca':['/usr/bin/pgrep','-f','orca-server-1.4'],'avd':['/usr/bin/pgrep','-f','qemu-system-aarch64']}
 for name,command in commands.items():
  try:
   r=subprocess.run(command,capture_output=True,text=True,timeout=15)
   result[name]={'code':r.returncode,'stdout':r.stdout.strip(),'stderr':r.stderr.strip()}
  except Exception as e: result[name]={'error':type(e).__name__+': '+str(e)}
 return result
record['before']=health()
try:
 disk=subprocess.check_output(['/usr/bin/hdiutil','attach','-nomount','ram://131072'],text=True).strip()
 if not re.fullmatch(r'/dev/disk[0-9]+',disk): raise RuntimeError('unexpected RAM disk identity')
 subprocess.run(['/usr/sbin/diskutil','eraseVolume','HFS+',volume,disk],check=True,stdout=subprocess.DEVNULL,timeout=20)
 info=plistlib.loads(subprocess.check_output(['/usr/sbin/diskutil','info','-plist',disk]));mount=pathlib.Path(info['MountPoint'])
 if info.get('VolumeName')!=volume or not 0<int(info['TotalSize'])<=70*1024*1024 or str(mount)!='/Volumes/'+volume: raise RuntimeError('RAM identity mismatch')
 package=mount/'input';package.mkdir(mode=0o700)
 for name,data in p['source'].items():
  relative=pathlib.PurePosixPath(name)
  if relative.is_absolute() or '..' in relative.parts: raise RuntimeError('invalid input path')
  b=base64.b64decode(data,validate=True)
  if hashlib.sha256(b).hexdigest()!=p['hashes'][name]: raise RuntimeError('input mismatch')
  f=package/name;f.parent.mkdir(parents=True,exist_ok=True);f.write_bytes(b)
 record['inputHashesMatched']=True;original=p['hashes'];p=None
 output=pathlib.Path(tempfile.mkdtemp(prefix='ccr-audio-output-',dir='/private/tmp'))
 commands=[['/usr/bin/xcrun','swiftc',str(package/'visionOSClient/VisionAudioBuffer.swift'),str(package/'Tests/checks/vision-audio-player/main.swift'),'-o',str(output/'pure'),'-module-cache-path',str(output/'cache')],[str(output/'pure')]]
 record['commandExitCodes']=[]
 for command in commands:
  child=subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,start_new_session=True)
  record['childPIDs'].append(child.pid)
  try: log,_=child.communicate(timeout=120)
  except subprocess.TimeoutExpired:
   os.killpg(child.pid,signal.SIGTERM)
   try: log,_=child.communicate(timeout=5)
   except subprocess.TimeoutExpired: os.killpg(child.pid,signal.SIGKILL);log,_=child.communicate(timeout=5)
  sys.stdout.buffer.write(log);sys.stdout.flush()
  record['commandExitCodes'].append(child.returncode)
  if child.returncode: break
 record['exitCode']=max(record['commandExitCodes'])
 record['memorySourcesUnchanged']=all(hashlib.sha256((package/n).read_bytes()).hexdigest()==h for n,h in original.items())
except Exception as e:
 record['error']=type(e).__name__+': '+str(e);record['exitCode']=2
finally:
 if child and child.poll() is None: os.killpg(child.pid,signal.SIGKILL);child.wait()
 record['childrenReaped']=child is None or child.poll() is not None
 if output: shutil.rmtree(output);record['outputRemoved']=not output.exists()
 if disk:
  r=subprocess.run(['/usr/bin/hdiutil','detach',disk],capture_output=True,text=True,timeout=20)
  record['detachCode']=r.returncode;record['sourceRemoved']=r.returncode==0 and not pathlib.Path('/Volumes',volume).exists()
 record['after']=health()
 print('RESULT_JSON '+json.dumps(record),flush=True)
sys.exit(record.get('exitCode',2) if record.get('sourceRemoved') and record.get('outputRemoved') else 2)
'''
def containers():
    result = subprocess.run(['/opt/homebrew/bin/docker', '--context', 'cargo24-mini', 'ps', '--format', '{{.ID}} {{.Names}} {{.Status}}'], capture_output=True, text=True, timeout=15)
    return {'code': result.returncode, 'stdout': result.stdout.strip(), 'stderr': result.stderr.strip()}

containers_before = containers()
process = subprocess.Popen(['/Users/ambrion/.local/bin/mini', 'heavy', '--cwd', '/private/tmp', '--', 'python3', '-B', '-c', runner], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
try:
    log, _ = process.communicate(payload, timeout=300)
except subprocess.TimeoutExpired:
    process.terminate()
    log, _ = process.communicate(timeout=30)
(OUT / (attempt + '.log')).write_bytes(log)
records = [line[len('RESULT_JSON '):] for line in log.decode(errors='replace').splitlines() if line.startswith('RESULT_JSON ')]
record = {'exitCode': process.returncode, 'transportPID': process.pid, 'transportReaped': process.poll() is not None,
          'sourceHEAD': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
          'scope': 'Independent pure component RAM validation; no native player, peer acceptance, or source-guard transfer acceptance',
          'inputSHA256': sha(payload), 'remoteInputHashMatched': ('INPUT_SHA256 ' + sha(payload)).encode() in log,
          'sourceSHA256': hashes, 'sourceUnchanged': all(sha((ROOT / name).read_bytes()) == value for name, value in hashes.items()),
          'remoteResult': json.loads(records[-1]) if records else None,
          'containersBefore': containers_before, 'containersAfter': containers()}
(OUT / (attempt + '.json')).write_text(json.dumps(record, indent=2) + '\n')
print(log.decode(errors='replace'))
print(json.dumps(record, indent=2))
sys.exit(process.returncode)

import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

from extract import ROOT, block, fixture

label = sys.argv[1]
out = ROOT / 'Tests/checks/reconnect-glue/receipts'
out.mkdir(exist_ok=True)
if (out / (label + '.json')).exists():
    raise SystemExit('reconcile existing receipt before another attempt')
files, extraction = fixture()
if '--cancel-mutation' in sys.argv:
    main = files['main.swift']
    background = block(main, 'private func wentToBackground()')
    call = '        cancelRemoteDial()\n'
    if background.count(call) != 1:
        raise SystemExit('expected exactly one production background cancellation call')
    mutant = main.replace(background, background.replace(call, ''), 1)
    files['cancel-mutant/main.swift'] = mutant
    extraction['backgroundCancelMutation'] = {
        'originalSHA256': hashlib.sha256(background.encode()).hexdigest(),
        'mutantSHA256': hashlib.sha256(background.replace(call, '').encode()).hexdigest(),
        'removed': call.strip(),
        'scope': 'One call removed from extracted production lifecycle; connector cancellation is recorded by a stand-in.'
    }
paths = [ROOT / p for p in ['iOSClient/StreamClient.swift', 'iOSClient/StreamClient+Remote.swift', 'iOSClient/DiscoveryPolicy.swift']]
if '--pointer' in sys.argv:
    for name in ['Sources/StreamProtocol/Input.swift', 'Sources/StreamProtocol/Switcher.swift', 'Sources/StreamProtocol/StreamMessage.swift', 'iOSClient/KeyChords.swift', 'visionOSClient/VisionPointer.swift', 'visionOSClient/VisionInputFence.swift', 'visionOSClient/VisionTransition.swift', 'Tests/vision-pointer/main.swift']:
        p = ROOT / name
        paths.append(p)
        files[name] = p.read_text()
sha = lambda b: hashlib.sha256(b).hexdigest()
original = {str(p.relative_to(ROOT)): sha(p.read_bytes()) for p in paths}
source = {name: base64.b64encode(value.encode()).decode() for name, value in files.items()}
hashes = {name: sha(value.encode()) for name, value in files.items()}
payload = json.dumps({'source': source, 'hashes': hashes}).encode()
runner = r'''
import base64,hashlib,json,os,pathlib,plistlib,re,signal,subprocess,sys,tempfile,uuid,shutil
raw=sys.stdin.buffer.read();print('INPUT_SHA256 '+hashlib.sha256(raw).hexdigest(),flush=True);p=json.loads(raw);raw=None
volume='CCRReconnect'+uuid.uuid4().hex[:10];disk=None;output=None;child=None;record={'runnerPID':os.getpid(),'childPIDs':[]}
def health():
 return {'swap':subprocess.check_output(['/usr/sbin/sysctl','vm.swapusage'],text=True).strip(),'pressure':subprocess.check_output(['/usr/bin/memory_pressure','-Q'],text=True).strip(),'orca':subprocess.run(['/usr/bin/pgrep','-f','orca-server-1.4'],capture_output=True,text=True).stdout.splitlines()}
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
 output=pathlib.Path(tempfile.mkdtemp(prefix='ccr-reconnect-output-',dir='/private/tmp'))
 cache=str(output/'cache')
 sources=[str(package/'DiscoveryPolicy.swift'),str(package/'main.swift')]
 if (package/'sleep.swift').exists(): sources.append(str(package/'sleep.swift'))
 commands=[['/usr/bin/xcrun','swiftc']+sources+['-o',str(output/'glue'),'-module-cache-path',cache],[str(output/'glue')]]
 if (package/'cancel-mutant/main.swift').exists():
  commands += [['/usr/bin/xcrun','swiftc',str(package/'DiscoveryPolicy.swift'),str(package/'cancel-mutant/main.swift'),str(package/'sleep.swift'),'-o',str(output/'cancel-mutant'),'-module-cache-path',cache],[str(output/'cancel-mutant')]]
 if (package/'Tests/vision-pointer/main.swift').exists():
  commands += [['/usr/bin/xcrun','swiftc','-parse-as-library','-emit-module','-emit-object','-whole-module-optimization','-module-name','StreamProtocol']+[str(package/('Sources/StreamProtocol/'+name+'.swift')) for name in ['Input','Switcher','StreamMessage']]+['-emit-module-path',str(output/'StreamProtocol.swiftmodule'),'-o',str(output/'Input.o'),'-module-cache-path',cache],['/usr/bin/xcrun','swiftc','-I',str(output),str(package/'visionOSClient/VisionPointer.swift'),str(package/'iOSClient/KeyChords.swift'),str(package/'visionOSClient/VisionInputFence.swift'),str(package/'visionOSClient/VisionTransition.swift'),str(package/'Tests/vision-pointer/main.swift'),str(output/'Input.o'),'-o',str(output/'pointer'),'-module-cache-path',cache],[str(output/'pointer')]]
 record['commandExitCodes']=[]
 for command in commands:
  child=subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,start_new_session=True)
  record['childPIDs'].append(child.pid)
  try: log,_=child.communicate(timeout=180)
  except subprocess.TimeoutExpired:
   os.killpg(child.pid,signal.SIGTERM)
   try: log,_=child.communicate(timeout=5)
   except subprocess.TimeoutExpired: os.killpg(child.pid,signal.SIGKILL);log,_=child.communicate(timeout=5)
  sys.stdout.buffer.write(log);sys.stdout.flush()
  if command == [str(output/'cancel-mutant')]:
   record['cancelMutationExitCode']=child.returncode
   record['cancelMutationFailures']=[line for line in log.decode(errors='replace').splitlines() if line.startswith('FAIL ')]
   record['cancelMutationDetected']=child.returncode==1 and b'PASS remote cancellation precondition has active connector at 103' in log and b'FAIL background immediately cancels retained active remote connector' in log
   record['commandExitCodes'].append(0 if record['cancelMutationDetected'] else 2)
  else: record['commandExitCodes'].append(child.returncode)
  if 'swiftc' in command and child.returncode: break
 record['exitCode']=0 if all(code==0 for code in record['commandExitCodes']) else 1
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
process = subprocess.Popen(['/Users/ambrion/.local/bin/mini', 'heavy', '--cwd', '/private/tmp', '--', 'python3', '-B', '-c', runner], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
try:
    log, _ = process.communicate(payload, timeout=600)
except subprocess.TimeoutExpired:
    process.terminate()
    log, _ = process.communicate(timeout=30)
(out / (label + '.log')).write_bytes(log)
records = [line[len('RESULT_JSON '):] for line in log.decode(errors='replace').splitlines() if line.startswith('RESULT_JSON ')]
record = {'exitCode': process.returncode, 'transportPID': process.pid, 'transportReaped': process.poll() is not None, 'sourceHEAD': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(), 'scope': 'Independent RAM input validation, not codex-source-guard transfer acceptance', 'inputSHA256': sha(payload), 'remoteInputHashMatched': ('INPUT_SHA256 ' + sha(payload)).encode() in log, 'sourceSHA256': original, 'sourceUnchanged': all(sha((ROOT / n).read_bytes()) == h for n, h in original.items()), 'extractionSHA256': extraction, 'remoteResult': json.loads(records[-1]) if records else None}
(out / (label + '.json')).write_text(json.dumps(record, indent=2) + '\n')
print(log.decode(errors='replace'))
print(json.dumps(record, indent=2))
sys.exit(process.returncode)

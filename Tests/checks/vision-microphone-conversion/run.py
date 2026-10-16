import json
from pathlib import Path
import re
import signal
import subprocess
import sys

MUTANTS = [
    ('output-capacity','iOSClient/IPadMicrophoneCapture.swift', 'frameCapacity: AVAudioFrameCount(expanded)', 'frameCapacity: AVAudioFrameCount(min(expanded, 4_096))', 'conversion-only','48k hardware buffer 4800 preserves all complete wire blocks'),
    ('input-request','iOSClient/IPadMicrophoneCapture.swift','let count = min(requested, input.frameLength - cursor)','let count = input.frameLength - cursor','conversion-only','upsampled 300ms preserves complete output beyond one converter buffer'),
    ('stream-sequence','iOSClient/IPadMicrophoneCapture.swift','if continuingStream { packetizer.discardPending() } else { packetizer.reset() }','packetizer.reset()','full','duplex format rebuild preserves wire sequence within grant'),
    ('permission-admission','visionOSClient/VisionMicrophoneCapture.swift','hardware.cleanupProblem == nil, permitted() else','hardware.cleanupProblem == nil else','full','missing grant requests no permission or hardware'),
    ('premature-ready','visionOSClient/VisionMicrophoneCapture.swift','                    })\n                } catch { finish(.failure(error)) }','                    })\n                    finish(.success(()))\n                } catch { finish(.failure(error)) }','full','reserved capture waits until actual graph commits'),
]

def main():
    root, output = [Path(p).resolve() for p in sys.argv[1:3]]
    output.mkdir(exist_ok=True,parents=True)
    record={'scope':'Actual AVAudioConverter, packetizer, capture adapter, hardware with inert graph/permission. No native engine/session/device/network IO.','commands':[],'mutants':[],'exitCode':2}
    sources=[root/'iOSClient/IPadMicrophoneCapture.swift',root/'iOSClient/IPadMicrophonePCM.swift',root/'visionOSClient/VisionAudioBuffer.swift',root/'visionOSClient/VisionAudioHardware.swift',root/'visionOSClient/VisionMicrophoneCapture.swift',root/'Tests/checks/vision-microphone-conversion/CaptureChecks.swift',root/'Tests/checks/vision-microphone-conversion/main.swift']
    base=['/usr/bin/xcrun','swiftc','-swift-version','5','-module-cache-path',str(output/'cache')]
    def run(command,label):
        child=subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,start_new_session=True)
        try: log,_=child.communicate(timeout=90)
        except subprocess.TimeoutExpired:
            import os
            os.killpg(child.pid,signal.SIGKILL);log,_=child.communicate(timeout=5)
        (output/(label+'.log')).write_text(log)
        record['commands'].append({'label':label,'exitCode':child.returncode,'reaped':child.poll() is not None})
        return child.returncode,log
    def compile_run(paths,label,mode='full'):
        exe=output/label
        code,log=run(base+list(map(str,paths))+['-o',str(exe)],label+'-compile')
        if code:raise RuntimeError(label+' compile\n'+log[-6000:])
        return run([str(exe)]+([] if mode=='full' else [mode]),label+'-runtime')
    try:
        code,log=compile_run(sources,'baseline')
        if code:raise RuntimeError('baseline\n'+log)
        record['assertions']=int(re.search(r'^RESULT_ASSERTIONS (\d+)$',log,re.M)[1])
        for name,path,old,new,mode,witness in MUTANTS:
            text=(root/path).read_text()
            if text.count(old)!=1:raise RuntimeError('mutant anchor '+name)
            variant=output/('variant-'+name);variant.mkdir()
            changed=variant/Path(path).name;changed.write_text(text.replace(old,new,1))
            entry={'name':name,'witness':witness,'mode':mode,'compiled':False,'caught':False};record['mutants'].append(entry)
            code,log=compile_run([changed if p==root/path else p for p in sources],name,mode)
            failed=re.findall(r'^FAIL (.*)$',log,re.M)
            entry.update(compiled=True,exitCode=code,failures=failed,caught=code==1 and witness in failed)
        record['exitCode']=0 if all(e['caught'] for e in record['mutants']) else 1
    except Exception as error:record['error']=str(error)
    (output/'result.json').write_text(json.dumps(record,indent=2)+'\n')
    print('SUITE_RESULT '+json.dumps(record),flush=True)
    return record['exitCode']
if __name__=='__main__':sys.exit(main())

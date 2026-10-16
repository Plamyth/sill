import json
from pathlib import Path
import signal
import subprocess
import sys

MUTANTS = []
def main():
    root, output = [Path(p).resolve() for p in sys.argv[1:3]]
    output.mkdir(exist_ok=True,parents=True)
    record={'scope':'Actual AVAudioConverter/PCM synthetic software buffers. No native engine, session, permissions, device or network.', 'commands':[], 'exitCode':2}
    sources=[root/'iOSClient/IPadMicrophoneCapture.swift',root/'iOSClient/IPadMicrophonePCM.swift',root/'Tests/checks/vision-microphone-conversion/main.swift']
    exe=output/'probe'
    commands=[['/usr/bin/xcrun','swiftc','-swift-version','5','-module-cache-path',str(output/'cache')]+list(map(str,sources))+['-o',str(exe)],[str(exe)]]
    try:
        for label,command in zip(['compile','runtime'],commands):
            child=subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,start_new_session=True)
            try: log,_=child.communicate(timeout=90)
            except subprocess.TimeoutExpired:
                import os
                os.killpg(child.pid,signal.SIGKILL);log,_=child.communicate(timeout=5)
            (output/(label+'.log')).write_text(log)
            record['commands'].append({'label':label,'exitCode':child.returncode,'reaped':child.poll() is not None})
            print(log,flush=True)
            if child.returncode: record['exitCode']=child.returncode;break
        else:record['exitCode']=0
    except Exception as error:record['error']=str(error)
    (output/'result.json').write_text(json.dumps(record,indent=2)+'\n')
    print('SUITE_RESULT '+json.dumps(record),flush=True)
    return record['exitCode']
if __name__=='__main__':sys.exit(main())

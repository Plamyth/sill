import json
from pathlib import Path
import re
import subprocess
import sys
MUTANTS=[]
def main():
    root,out=[Path(x).resolve() for x in sys.argv[1:3]]
    out.mkdir(exist_ok=True,parents=True)
    record={'scope':'Actual converter sequential original4800 buffers and distinct signal levels. No IO, no native engine, no permission.','exitCode':2,'commands':[]}
    sources=[root/'iOSClient/IPadMicrophoneCapture.swift',root/'iOSClient/IPadMicrophonePCM.swift',root/'Tests/checks/vision-microphone-accounting/main.swift']
    try:
        for label,cmd in [('compile',['/usr/bin/xcrun','swiftc','-swift-version','5','-module-cache-path',str(out/'cache')]+list(map(str,sources))+['-o',str(out/'check')]),('runtime',[str(out/'check')])]:
            r=subprocess.run(cmd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=90)
            (out/(label+'.log')).write_text(r.stdout)
            record['commands'].append({'label':label,'exitCode':r.returncode})
            if r.returncode:record['error']=r.stdout;record['exitCode']=r.returncode;break
            if label=='runtime':record['assertions']=int(re.search(r'^RESULT_ASSERTIONS (\d+)$',r.stdout,re.M)[1]);record['output']=r.stdout;record['exitCode']=0
    except Exception as e:record['error']=str(e)
    (out/'result.json').write_text(json.dumps(record,indent=2)+'\n')
    print('SUITE_RESULT '+json.dumps(record),flush=True)
    return record['exitCode']
if __name__=='__main__':sys.exit(main())

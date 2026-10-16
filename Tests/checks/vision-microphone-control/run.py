import json
from pathlib import Path
import re
import signal
import subprocess
import sys

MUTANTS=[]
def main():
    root,output=[Path(x).resolve() for x in sys.argv[1:3]]
    output.mkdir(exist_ok=True,parents=True)
    record={'scope':'Actual policy/framegate/Vision effect extension with inert Network/capture boundaries; actual controller/player/capture/hardware duplex shutdown with inert graph. No native IO.','commands':[],'exitCode':2}
    base=['/usr/bin/xcrun','swiftc','-swift-version','5','-module-cache-path',str(output/'cache')]
    def run(cmd,label):
        child=subprocess.Popen(cmd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,start_new_session=True)
        try:log,_=child.communicate(timeout=90)
        except subprocess.TimeoutExpired:
            import os
            os.killpg(child.pid,signal.SIGKILL);log,_=child.communicate(timeout=5)
        (output/(label+'.log')).write_text(log)
        record['commands'].append({'label':label,'exitCode':child.returncode,'reaped':child.poll() is not None})
        print(log,flush=True)
        return child.returncode,log
    def require(cmd,label):
        code,log=run(cmd,label)
        if code:raise RuntimeError(label+'\n'+log[-5000:])
        return log
    def module(name,paths):
        require(base+['-parse-as-library','-whole-module-optimization','-emit-module','-emit-object','-module-name',name]+list(map(str,paths))+['-emit-module-path',str(output/(name+'.swiftmodule')),'-o',str(output/(name+'.o'))],name+'-compile')
    try:
        module('Network',[root/'Tests/checks/vision-microphone-control/Network.swift'])
        module('StreamProtocol',[root/'Sources/StreamProtocol'/(n+'.swift') for n in ['StreamMessage','AudioPacket','Switcher','MicrophoneUplink','Input','Viewport','HostSettings','Compatibility']])
        sources=[root/'iOSClient'/(n+'.swift') for n in ['IPadMicrophonePCM','IPadMicrophonePolicy','IPadMicrophoneFrameGate']]
        sources += [root/'visionOSClient/StreamClient+VisionMicrophone.swift',root/'Tests/checks/vision-microphone-control/main.swift']
        objects=[str(output/'Network.o'),str(output/'StreamProtocol.o')]
        require(base+['-D','VISION_MICROPHONE_CHECKS','-I',str(output)]+list(map(str,sources))+objects+['-o',str(output/'control')],'control-compile')
        code,log=run([str(output/'control')],'control-runtime')
        record['controlExit']=code
        record['controlAssertions']=int(re.search(r'^RESULT_ASSERTIONS (\d+)$',log,re.M)[1]) if re.search(r'^RESULT_ASSERTIONS (\d+)$',log,re.M) else None
        generated=output/'duplex';generated.mkdir()
        main=generated/'main.swift';main.write_text('import Foundation\nexit(runDuplexRegression())\n')
        sources=[root/'visionOSClient'/(n+'.swift') for n in ['VisionAudioBuffer','VisionAudioHardware','VisionAudioPlayer','VisionAudioState','VisionAudioController','VisionMicrophoneCapture']]
        sources += [root/'iOSClient'/(n+'.swift') for n in ['IPadMicrophonePCM','IPadMicrophoneCapture']]
        sources += [root/'Tests/checks/vision-microphone-control/Duplex.swift',main]
        require(base+['-I',str(output)]+list(map(str,sources))+objects+['-o',str(output/'duplex-check')],'duplex-compile')
        code2,log=run([str(output/'duplex-check')],'duplex-runtime')
        record['duplexExit']=code2
        record['duplexAssertions']=int(re.search(r'^RESULT_ASSERTIONS (\d+)$',log,re.M)[1]) if re.search(r'^RESULT_ASSERTIONS (\d+)$',log,re.M) else None
        record['exitCode']=0 if code==0 and code2==0 else 1
    except Exception as error:record['error']=str(error)
    (output/'result.json').write_text(json.dumps(record,indent=2)+'\n')
    print('SUITE_RESULT '+json.dumps(record),flush=True)
    return record['exitCode']
if __name__=='__main__':sys.exit(main())

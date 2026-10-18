import hashlib
import json
from pathlib import Path
import re
import signal
import subprocess
import sys

MUTANTS=[
    ('pending-batches','iOSClient/IPadMicrophoneFrameGate.swift','current.pending < 2','current.pending < 3','control','bounded pending count applies to complete hardware batches'),
    ('scope-close','iOSClient/IPadMicrophoneFrameGate.swift','if binding?.captureID == captureID { binding = nil }','binding = nil','control','old scoped close cannot close a replacement grant'),
    ('batch-tail','iOSClient/IPadMicrophoneFrameGate.swift','for block in blocks {','for block in blocks.prefix(2) {','control','framed batch preserves every100ms packet in original wire format'),
    ('revoked-sibling','visionOSClient/VisionAudioHardware.swift','if revoked.contains(.playback) { playback = nil }','_ = revoked','duplex','healthy revoked sibling does not quarantine shared hardware'),
    ('ack-identity','iOSClient/IPadMicrophonePolicy.swift','let matchesStart = state.requestID == startRequestID','let matchesStart = true','control','wrong request and peer cannot begin capture'),
]

def main():
    root,output=[Path(x).resolve() for x in sys.argv[1:3]]
    output.mkdir(exist_ok=True,parents=True)
    record={'scope':'Actual policy/framegate/Vision glue with inert Network; actual controller/player/capture/hardware duplex; actual fullclient producer-to-wire with only permission factory argument substituted. No native IO.','commands':[],'mutants':[],'exitCode':2}
    base=['/usr/bin/xcrun','swiftc','-swift-version','5','-module-cache-path',str(output/'cache')]
    def run(cmd,label):
        child=subprocess.Popen(cmd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,start_new_session=True)
        try:log,_=child.communicate(timeout=90)
        except subprocess.TimeoutExpired:
            import os
            os.killpg(child.pid,signal.SIGKILL);log,_=child.communicate(timeout=5)
        (output/(label+'.log')).write_text(log)
        record['commands'].append({'label':label,'exitCode':child.returncode,'reaped':child.poll() is not None})
        return child.returncode,log
    def require(cmd,label):
        code,log=run(cmd,label)
        if code:raise RuntimeError(label+'\n'+log[-5000:])
        return log
    def module(name,paths):
        require(base+['-parse-as-library','-whole-module-optimization','-emit-module','-emit-object','-module-name',name]+list(map(str,paths))+['-emit-module-path',str(output/(name+'.swiftmodule')),'-o',str(output/(name+'.o'))],name+'-compile')
    try:
        module('Network',[root/'Tests/checks/vision-microphone-control/Network.swift'])
        module('StreamProtocol',[root/'Sources/StreamProtocol'/(n+'.swift') for n in ['StreamMessage','AudioPacket','Switcher','MicrophoneUplink','Input','Viewport','HostSettings','Compatibility','AudioRouting']])
        objects=[str(output/'Network.o'),str(output/'StreamProtocol.o')]
        control=[root/'iOSClient'/(n+'.swift') for n in ['IPadMicrophonePCM','IPadMicrophonePolicy','IPadMicrophoneFrameGate']]
        control += [root/'visionOSClient/VisionCableBootstrap.swift',root/'visionOSClient/StreamClient+VisionMicrophone.swift',root/'Tests/checks/vision-microphone-control/main.swift']
        generated=output/'generated';generated.mkdir()
        main=generated/'main.swift';main.write_text('import Foundation\nexit(runDuplexRegression())\n')
        duplex=[root/'visionOSClient'/(n+'.swift') for n in ['VisionAudioBuffer','VisionAudioHardware','VisionAudioPlayer','VisionAudioState','VisionAudioController','VisionMicrophoneCapture']]
        duplex += [root/'iOSClient'/(n+'.swift') for n in ['IPadMicrophonePCM','IPadMicrophoneCapture']]
        duplex += [root/'Tests/checks/vision-microphone-control/Duplex.swift',main]
        def compile_run(paths,label):
            exe=output/label
            require(base+['-D','VISION_MICROPHONE_CHECKS','-I',str(output)]+list(map(str,paths))+objects+['-o',str(exe)],label+'-compile')
            return run([str(exe)],label+'-runtime')
        record['assertions']={}
        for name,paths in [('control',control),('duplex',duplex)]:
            code,log=compile_run(paths,name)
            if code:raise RuntimeError(name+' baseline\n'+log)
            record['assertions'][name]=int(re.search(r'^RESULT_ASSERTIONS (\d+)$',log,re.M)[1])
        actual=output/'actual-client';actual.mkdir()
        main2=actual/'main.swift';main2.write_bytes((root/'Tests/checks/vision-microphone-control/client-main.swift').read_bytes())
        original=(root/'visionOSClient/StreamClient+VisionMicrophone.swift').read_text()
        old='}, closeFrames: { frames.close(captureID: captureID) }'
        if original.count(old)!=1:raise RuntimeError('actual permission boundary anchor')
        adapted=original.replace(old,'}, requestPermission: testPermission, closeFrames: { frames.close(captureID: captureID) }',1)
        glue=actual/'Glue.swift';glue.write_text(adapted)
        record['actualFactoryBoundary']={'sourceSHA256':hashlib.sha256(original.encode()).hexdigest(),'emittedSHA256':hashlib.sha256(adapted.encode()).hexdigest(),'substitution':'Capture requestPermission seam injected as an inert permission check; OS authorization is supplied by the inert StreamClient factory. Actual adapter/capture/worker/policy/framegate/hardware bodies unchanged.'}
        actualSources=[root/'visionOSClient'/(n+'.swift') for n in ['VisionAudioBuffer','VisionAudioHardware','VisionMicrophoneCapture','VisionCableBootstrap']]
        actualSources += [root/'iOSClient'/(n+'.swift') for n in ['IPadMicrophonePCM','IPadMicrophoneCapture','IPadMicrophonePolicy','IPadMicrophoneFrameGate']]
        actualSources += [root/'Tests/checks/vision-microphone-control/Client.swift',glue,main2]
        code,log=compile_run(actualSources,'actualclient')
        if code:raise RuntimeError('actualclient baseline\n'+log)
        record['assertions']['actualClient']=int(re.search(r'^RESULT_ASSERTIONS (\d+)$',log,re.M)[1])
        for name,path,old,new,group,witness in MUTANTS:
            text=(root/path).read_text()
            if text.count(old)!=1:raise RuntimeError('mutation anchor '+name)
            variant=output/('variant-'+name);variant.mkdir()
            changed=variant/Path(path).name;changed.write_text(text.replace(old,new,1))
            paths=control if group=='control' else duplex
            entry={'name':name,'group':group,'witness':witness,'compiled':False,'caught':False};record['mutants'].append(entry)
            code,log=compile_run([changed if p==root/path else p for p in paths],name)
            failed=re.findall(r'^FAIL (.*)$',log,re.M)
            entry.update(compiled=True,exitCode=code,failures=failed,caught=code==1 and witness in failed)
        record['exitCode']=0 if all(e['caught'] for e in record['mutants']) else 1
    except Exception as error:record['error']=str(error)
    (output/'result.json').write_text(json.dumps(record,indent=2)+'\n')
    print('SUITE_RESULT '+json.dumps(record),flush=True)
    return record['exitCode']
if __name__=='__main__':sys.exit(main())

from pathlib import Path
import importlib.util, subprocess, sys
root=Path(__file__).resolve().parents[3]
out=Path(sys.argv[1])
flags=['-swift-version','5','-whole-module-optimization','-module-cache-path',str((out/'cache').resolve()),'-I',str(out),'-L',str(out),'-lStreamProtocol','-Xlinker','-rpath','-Xlinker',str(out)]
files=['IPadDesiredAudio.swift','IPadMicrophonePolicy.swift','IPadRemoteAudioController.swift','IPadAudioRoutePolicy.swift','IPadAudioAdmission.swift']
def run(cmd): subprocess.run(cmd,check=True,timeout=150)
run(['/usr/bin/xcrun','swiftc',*flags,*[str(root/'iOSClient'/n) for n in files],str(root/'Tests/checks/ipad-desired-audio/main.swift'),'-o',str(out/'pure')])
run([str(out/'pure')])
p=root/'Tests/checks/ipad-desired-audio/permission-lifecycle.py'
spec=importlib.util.spec_from_file_location('permission',p); module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
for name,source in module.sources(root).items(): (out/name).write_text(source)
run(['/usr/bin/xcrun','swiftc',*flags,'-parse-as-library',*[str(root/'iOSClient'/n) for n in files],str(out/'Adapter.swift'),str(out/'main.swift'),'-o',str(out/'permission')])
run([str(out/'permission')])

run(['/usr/bin/xcrun','swiftc',*flags,str(root/'iOSClient/IPadAudioAdmission.swift'),str(root/'iOSClient/IPadMicrophonePCM.swift'),str(root/'iOSClient/IPadMicrophoneFrameGate.swift'),str(out/'Diagnostics.swift'),str(root/'Tests/checks/ipad-microphone-frame-gate/main.swift'),'-o',str(out/'default-gate')])
run([str(out/'default-gate')])
run(['python3','-B',str(root/'Tests/checks/iPad-remote-audio/fixture.py'),str(root),str(out)])
run(['python3','-B',str(root/'Tests/checks/iPad-remote-audio/player-fixture.py'),str(root),str(out)])
run(['/usr/bin/xcrun','swiftc',*flags,'-parse-as-library',str(root/'iOSClient/IPadAudioAdmission.swift'),str(root/'iOSClient/IPadRemoteAudioController.swift'),str(out/'Diagnostics.swift'),str(out/'ClientFixture.swift'),str(out/'PlaybackFixture.swift'),str(root/'Tests/checks/iPad-remote-audio/main.swift'),'-o',str(out/'legacy-playback')])
run([str(out/'legacy-playback'),str(out)])

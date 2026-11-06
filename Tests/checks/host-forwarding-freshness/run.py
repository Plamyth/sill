"""Compile full production relay/runtime with inert boundaries; actual pipes only."""
from pathlib import Path
import os
import signal
import subprocess
import tempfile

root=Path(__file__).resolve().parents[3]
here=Path(__file__).resolve().parent
names=['HostLog','LocalAudioParticipants','LocalAudioRelay','AudioForwardingContract','AudioForwardingCoordinator','AudioForwardingParticipants','AudioForwardingProtection','HostAudioForwardingRuntime']
with tempfile.TemporaryDirectory(prefix='forwarding-freshness-') as temporary:
    out=Path(temporary)
    relay=out/'Relay.swift'
    relay.write_text((root/'Sources/SillHost/LocalAudioRelay.swift').read_text()+'\n'+(root/'Tests/checks/native-relay-rpc-order/Probe.swift').read_text())
    runtime=out/'Runtime.swift'
    runtime.write_text((root/'Sources/SillHost/HostAudioForwardingRuntime.swift').read_text()+'''\nextension HostAudioForwardingRuntime {
    func checkPausePolling(){polling?.cancel();polling=nil}
}
''')
    bridge=(root/'Sources/SillHost/ProviderCallBridge.swift').read_text()
    provider=(root/'Sources/SillHost/ProviderCallRuntime.swift').read_text()
    scope=out/'ProviderScope.swift'
    scope.write_text(bridge[:bridge.index('struct ProviderCallSignedEnvelope:')]+bridge[bridge.index('struct ProviderCallChallenge:'):bridge.index('private struct ProviderIdentityBody:')]+provider[provider.index('@MainActor\nstruct ProviderCallSession {'):provider.index('@MainActor\nfinal class ProviderCallRuntime {')])
    swift=['xcrun','swiftc','-package-name','Sill','-module-cache-path',str(out/'cache')]
    subprocess.run(swift+['-emit-module','-emit-library','-module-name','StreamProtocol',*map(str,sorted((root/'Sources/StreamProtocol').glob('*.swift'))),'-emit-module-path',str(out/'StreamProtocol.swiftmodule'),'-o',str(out/'libStreamProtocol.dylib')],check=True)
    sources=[root/'Sources/SillHost'/f'{n}.swift' for n in names if n not in ['LocalAudioRelay','HostAudioForwardingRuntime']]
    subprocess.run(swift+['-parse-as-library','-I',str(out),'-L',str(out),'-lStreamProtocol','-Xlinker','-rpath','-Xlinker',str(out),*map(str,sources),str(relay),str(runtime),str(scope),str(root/'Tests/checks/forwarding-evidence-lifecycle/Boundaries.swift'),str(here/'Main.swift'),'-o',str(out/'checks')],check=True)
    worker=subprocess.Popen([str(out/'checks'),str(here/'child.py'),str(out/'case')],start_new_session=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,env={**os.environ,'DYLD_LIBRARY_PATH':str(out)})
    try:
        output,_=worker.communicate(timeout=35)
        print(output,end='')
    finally:
        try:os.killpg(worker.pid,signal.SIGKILL)
        except ProcessLookupError:pass
    raise SystemExit(worker.returncode)

#!/usr/bin/env python3
from pathlib import Path
import subprocess, tempfile, os, hashlib, json
root=Path(__file__).resolve().parents[3]
with tempfile.TemporaryDirectory(prefix='peer-session-') as tmp:
    out=Path(tmp)
    protocol=sorted((root/'Sources/StreamProtocol').glob('*.swift'))
    def run(args): subprocess.run(args,cwd=out,check=True)
    run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-emit-library','-emit-module','-module-name','StreamProtocol',*[str(p) for p in protocol],'-o',str(out/'libStreamProtocol.dylib')])
    driver=(root/'Sources/SillHost/PeerCaptureDriver.swift').read_text().split('/// Captures the existing window/display in place.')[0]
    driver+='\nenum NativePeerCaptureDriver { enum Failure: Error { case unavailable, changed, invalidGeometry } }\n'
    (out/'Driver.swift').write_text(driver)
    server=(root/'Sources/SillHost/StreamServer.swift').read_text()
    admission=server[server.index('final class SourcePublicationAdmission:'):server.index('/// Advertises _sill._tcp')]
    (out/'Admission.swift').write_text('import Foundation\n'+admission)
    sources=['Sources/SillHost/HostConfig.swift','Sources/SillHost/DisplayInventory.swift','Sources/SillHost/PeerStreamState.swift','Sources/SillHost/PeerStreamSession.swift','Tests/checks/peer-stream-session/main.swift']
    before={p:hashlib.sha256((root/p).read_bytes()).hexdigest() for p in sources}
    run(['xcrun','swiftc','-swift-version','5','-package-name','sill','-parse-as-library','-I',str(out),'-L',str(out),'-lStreamProtocol','-Xlinker','-rpath','-Xlinker',str(out),*[str(root/p) for p in sources],str(out/'Driver.swift'),str(out/'Admission.swift'),'-o',str(out/'checks')])
    run([str(out/'checks')])
    run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-I',str(out),'-L',str(out),'-lStreamProtocol','-Xlinker','-rpath','-Xlinker',str(out),str(root/'Tests/checks/peer-stream-session/wire.swift'),'-o',str(out/'wire-checks')])
    run([str(out/'wire-checks')])
    assert before=={p:hashlib.sha256((root/p).read_bytes()).hexdigest() for p in sources}
    print(json.dumps({'sourceUnchanged':True,'scope':'production control session; native capture protocol replaced by inert driver; no physical acceptance'}))

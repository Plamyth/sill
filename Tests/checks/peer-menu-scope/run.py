from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[3]
here=Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix='peer-menu-') as tmp:
 out=Path(tmp)
 def run(args): subprocess.run(args,cwd=out,check=True)
 run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-emit-library','-emit-module','-module-name','StreamProtocol',*map(str,(root/'Sources/StreamProtocol').glob('*.swift')),'-o',str(out/'libStreamProtocol.dylib')])
 server=(root/'Sources/SillHost/StreamServer.swift').read_text()
 (out/'Admission.swift').write_text('import Foundation\n'+server[server.index('final class SourcePublicationAdmission:'):server.index('/// Advertises _sill._tcp')])
 mirror=(root/'Sources/SillHost/MenuMirror.swift').read_text().replace('private ', '')
 (out/'MenuMirror.swift').write_text(mirror)
 run(['xcrun','swiftc','-swift-version','5','-package-name','sill','-parse-as-library','-I',str(out),'-L',str(out),'-lStreamProtocol','-Xlinker','-rpath','-Xlinker',str(out),str(out/'Admission.swift'),str(out/'MenuMirror.swift'),str(root/'Sources/SillHost/MenuFormat.swift'),str(root/'Sources/SillHost/MenuPolicy.swift'),str(here/'Fixture.swift'),str(here/'main.swift'),'-o',str(out/'checks')])
 run([str(out/'checks')])

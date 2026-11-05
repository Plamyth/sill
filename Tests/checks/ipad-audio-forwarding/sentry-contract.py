"""Exact82 RED and Host241 GREEN, plus existing model/adapters, without device or audio."""
from pathlib import Path
import hashlib,os,subprocess,tempfile
root=Path(__file__).resolve().parents[3];here=Path(__file__).resolve().parent
source=(root/'Sources/StreamProtocol/AudioForwarding.swift').read_text()
assert hashlib.sha256(source.encode()).hexdigest()=='cdffb373f6469a852aaeff341c5d3fb4e67aa7ae49ee0030ec9c267448f9dc09','must equal exact Host241 DTO bytes'
legacy=source.replace('sentryDesired: Bool = false, localMutedDesired: Bool = true) throws {','sentryDesired: Bool = true, localMutedDesired: Bool = true) throws {',1).replace('guard intentRevision.value > 0, localMutedDesired','guard intentRevision.value > 0, sentryDesired, localMutedDesired')
assert hashlib.sha256(legacy.encode()).hexdigest()=='5667ceac9a01cb80ca7a5bd3ecf88a0b7906088fb647a9b116141632fa93b843','legacy must equal exact82 DTO bytes'
with tempfile.TemporaryDirectory(prefix='sentry-contract-') as folder:
 out=Path(folder).resolve();(out/'Legacy.swift').write_text(legacy)
 subprocess.run(['sh',str(here/'run.sh'),str(out)],check=True,cwd=root)
 flags=['xcrun','swiftc','-module-cache-path',str(out/'cache')]
 subprocess.run(flags+['-emit-library','-emit-module','-module-name','LegacyForwarding',str(out/'Legacy.swift'),'-o',str(out/'libLegacyForwarding.dylib'),'-emit-module-path',str(out/'LegacyForwarding.swiftmodule')],check=True)
 subprocess.run(flags+['-parse-as-library','-I',str(out),'-L',str(out),'-lStreamProtocol','-lLegacyForwarding','-Xlinker','-rpath','-Xlinker',str(out),str(here/'sentry-contract.swift'),'-o',str(out/'contract')],check=True)
 subprocess.run([str(out/'contract'),str(here/'sentry-false-intent25.json')],check=True)
 subprocess.run(['python3','-B',str(here/'adapter.py'),str(out)],check=True)
print('scratchRemoved='+str(not out.exists()).lower())

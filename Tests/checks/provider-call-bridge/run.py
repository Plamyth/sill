"""Compile actual protocol/bridge and selected production identity/context, without app startup."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
with tempfile.TemporaryDirectory(prefix='provider-bridge-') as temporary:
    output = Path(temporary)
    swift = ['/usr/bin/xcrun','swiftc','-swift-version','5','-package-name','Sill','-module-cache-path',str(output/'cache')]
    subprocess.run(swift+['-emit-library','-emit-module','-module-name','StreamProtocol',
        *map(str,sorted((root/'Sources/StreamProtocol').glob('*.swift'))),'-o',str(output/'libStreamProtocol.dylib'),
        '-emit-module-path',str(output/'StreamProtocol.swiftmodule')],check=True)
    model = (root/'Sources/SillHost/ProviderCallBridge.swift').read_text()
    model = model[:model.index('struct ProviderCallSignedEnvelope:')]
    (output/'Models.swift').write_text(model)
    subprocess.run(swift+['-I',str(output),'-L',str(output),'-lStreamProtocol',str(output/'Models.swift'),
        str(root/'Tests/checks/provider-call-bridge/Main.swift'),'-o',str(output/'checks')],check=True)
    subprocess.run([str(output/'checks')],env={**os.environ,'DYLD_LIBRARY_PATH':str(output)},check=True)

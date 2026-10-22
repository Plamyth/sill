#!/usr/bin/env python3
"""실제 Vision 등록 어댑터와 공통 교환·dialer를 격리 대역에서 실행한다."""
import os,subprocess,sys,tempfile,importlib.util
from pathlib import Path
HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[2]
CLIENT=ROOT/'iOSClient'
subprocess.run([sys.executable,str(HERE/'project.py')],check=True)
with tempfile.TemporaryDirectory(prefix='vision-owner-') as folder:
    out=Path(folder); cache=out/'cache';env=dict(os.environ,CLANG_MODULE_CACHE_PATH=str(cache))
    subprocess.run(['swiftc','-module-cache-path',str(cache),'-emit-library','-emit-module','-module-name','StreamProtocol',*map(str,sorted((ROOT/'Sources/StreamProtocol').glob('*.swift'))),'-o',str(out/'libStreamProtocol.dylib')],check=True,env=env,timeout=180)
    common=['swiftc','-module-cache-path',str(cache),'-I',str(out),'-L',str(out),'-lStreamProtocol','-Xlinker','-rpath','-Xlinker',str(out)]
    owner=(ROOT/'visionOSClient/StreamClient+VisionOwnerBootstrap.swift').read_text().replace('import Network\n','').replace('import UIKit\n','').replace('#if os(visionOS)','#if true')
    exchange=(CLIENT/'OwnerBootstrapExchange.swift').read_text().replace('import Network\n','')
    lease=(ROOT/'visionOSClient/VisionCableBootstrap.swift').read_text().split('enum VisionCableBootstrapReason')[0]
    spec=importlib.util.spec_from_file_location('vision_startup_checks',ROOT/'Tests/checks/vision-autoconnect/run.py')
    extractor=importlib.util.module_from_spec(spec);spec.loader.exec_module(extractor)
    start=extractor.vision(extractor.block((CLIENT/'StreamClient+Remote.swift').read_text(),'func startRemote()'))
    body=(HERE/'Standins.swift').read_text()+lease+'extension StreamClient {\n'+start+'\n}\n'+owner+exchange+(HERE/'scenarios.swift').read_text()
    (out/'main.swift').write_text(body)
    subprocess.run(common+[str(CLIENT/'SavedMacs.swift'),str(CLIENT/'OwnerBootstrapState.swift'),str(out/'main.swift'),'-o',str(out/'checks')],check=True,env=env,timeout=180)
    subprocess.run([str(out/'checks'),str(out/'profile.json')],check=True,timeout=30)
    connector=(CLIENT/'RemoteConnector.swift').read_text().replace('import Network\n','')
    (out/'main.swift').write_text((HERE/'Connector.swift').read_text().replace('// ACTUAL_CONNECTOR',connector))
    subprocess.run(common+[str(out/'main.swift'),'-o',str(out/'connector')],check=True,env=env,timeout=180)
    subprocess.run([str(out/'connector')],check=True,timeout=30)

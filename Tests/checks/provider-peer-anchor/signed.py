"""Test-only signed UDS sender and peer policy. No installed app, listener or key changes."""
from pathlib import Path
import json
import plistlib
import socket
import subprocess
import tempfile

root = Path(__file__).resolve().parent
repo = root.parents[2]
identity = 'Apple Development: TAEWAN KANG (X6V8DN2VJ3)'
with tempfile.TemporaryDirectory(prefix='peer-fixture-') as scratch:
    work = Path(scratch)
    app = work / 'PeerFixture.app'
    executable = app / 'Contents/MacOS/peer'
    executable.parent.mkdir(parents=True)
    plist = {'CFBundleIdentifier':'com.ambrion.ccr.peer.fixture','CFBundleExecutable':'peer',
             'CFBundleVersion':'1','CFBundlePackageType':'APPL'}
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps(plist))
    subprocess.run(['/usr/bin/xcrun','swiftc',str(root/'fixture.swift'),'-o',str(executable)],check=True)
    subprocess.run(['/usr/bin/codesign','--force','--sign',identity,'--timestamp=none',str(app)],check=True)
    helper = work/'fixture-verifier'
    subprocess.run(['/usr/bin/xcrun','swiftc',str(repo/'Sources/ProviderPeerVerifier/PeerAnchor.swift'),
        str(root/'fixture-verifier.swift'),'-o',str(helper)],check=True)
    production = work/'production-verifier'
    subprocess.run(['/usr/bin/xcrun','swiftc',str(repo/'Sources/ProviderPeerVerifier/PeerAnchor.swift'),
        str(repo/'Sources/ProviderPeerVerifier/main.swift'),'-o',str(production)],check=True)
    checks = 0
    for kind in ['positive','wrong-bundle','wrong-team','wrong-path','production-policy','terminated-peer','replaced-code']:
        endpoint = work/'test.sock'
        server = socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
        server.settimeout(5)
        server.bind(str(endpoint));server.listen(1)
        peer = subprocess.Popen([str(executable),str(endpoint)],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
        connection = None
        try:
            connection,_ = server.accept()
            args = [str(helper),str(app),'com.ambrion.ccr.peer.fixture','ZPTXHJ866D']
            if kind == 'wrong-bundle':args[2] = 'com.ambrion.wrong'
            if kind == 'wrong-team':args[3] = 'AAAAAAAAAA'
            if kind == 'wrong-path':args[1] = str(work/'Other.app')
            if kind == 'production-policy':args = [str(production)]
            if kind == 'terminated-peer':
                peer.terminate();peer.wait(timeout=5)
            if kind == 'replaced-code':
                plist['CFBundleVersion'] = '2'
                (app/'Contents/Info.plist').write_bytes(plistlib.dumps(plist))
                subprocess.run(['/usr/bin/codesign','--force','--sign',identity,'--timestamp=none',str(app)],check=True)
            result = subprocess.run(['/opt/homebrew/bin/node',str(root/'relay.js'),str(connection.fileno()),*args],
                pass_fds=(connection.fileno(),),capture_output=True,text=True,timeout=10)
            value = json.loads(result.stdout)
            if kind == 'positive':
                assert result.returncode == 0 and value['state'] == 'verified', (kind,result.stdout,result.stderr)
                assert value['pid'] == peer.pid and value['application'] == str(app)
                assert len(value['peerTokenSHA256']) == 64 and len(value['codeDirectoryHash']) == 40
            else:assert result.returncode == 2 and value['state'] == 'refused',(kind,result.stdout,result.stderr)
            checks += 1
            print(json.dumps({'case':kind,'passed':True,'productionPositiveAccepted':False}),flush=True)
        finally:
            if connection:connection.close()
            server.close();endpoint.unlink(missing_ok=True)
            if peer.poll() is None:peer.wait(timeout=12)
    print(json.dumps({'checks':checks,'actualHostChanged':False,'audioActions':0,'temporaryFixturePolicyOnly':True}))

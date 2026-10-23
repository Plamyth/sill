"""Probe inherited anonymous UDS peer identity. Never connects to installed CCR or audio."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile

root = Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix='provider-peer-anchor-') as temporary:
    binary = Path(temporary) / 'peer-probe'
    subprocess.run(['/usr/bin/xcrun','swiftc',str(root/'probe.swift'),'-o',str(binary)],check=True)
    local,peer = socket.socketpair(socket.AF_UNIX,socket.SOCK_STREAM)
    try:
        result = subprocess.run(['/opt/homebrew/bin/node',str(root/'relay.js'),str(peer.fileno()),str(binary)],
            pass_fds=(peer.fileno(),),capture_output=True,text=True,timeout=15)
        assert result.returncode == 0,(result.returncode,result.stderr,result.stdout)
        value = json.loads(result.stdout)
        assert value['osPeerIdentified'] is True
        assert value['peerPID'] == os.getpid()
        assert value['requiredSignatureMatches'] is False
        assert value['hostTrusted'] is False and value['identityKeyRead'] is False
        print(json.dumps({'inheritedSocket':True,'kernelAuditPeerIdentified':True,
            'forgedHostRejected':True,'actualHostPositiveTest':False,'actualHostChanged':False}))
    finally:
        local.close();peer.close()
    invalid = subprocess.run([str(binary)],capture_output=True,text=True,timeout=10)
    assert invalid.returncode == 2 and not json.loads(invalid.stdout)['hostTrusted']
    print('PASS missing socket rejected; no host/UI/key/audio actions')

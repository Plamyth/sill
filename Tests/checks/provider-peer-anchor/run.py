"""Probe inherited anonymous UDS peer identity. Never connects to installed CCR or audio."""
import json
import os
from pathlib import Path
import socket
import subprocess
import select
import struct
import tempfile

root = Path(__file__).resolve().parent


def check_liveness(work):
    source = root.parents[2] / 'Sources/SillHost/ProviderPeerAnchor.swift'
    instrumented = work / 'PeerAnchor.swift'
    instrumented.write_text(source.read_text() + '''
extension ProviderPeerAnchor {
    static func checkLiveness(_ fd: Int32) throws { try requireLiveSocket(fd) }
}
''')
    binary = work / 'liveness'
    subprocess.run(['/usr/bin/xcrun', 'swiftc', str(instrumented), str(root/'liveness.swift'),
                    '-o', str(binary)], check=True)
    for mode in ['idle', 'data', 'peer-closed', 'data-peer-closed', 'closed-fd', 'negative-fd',
                 'eintr-idle', 'eintr-peer-closed', 'poll-error', 'pollerr']:
        with tempfile.TemporaryDirectory(prefix='ppl-', dir='/tmp') as endpoint_dir:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server, \
                    socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                server.bind(str(Path(endpoint_dir)/'s'))
                server.listen(1)
                client.connect(server.getsockname())
                accepted, _ = server.accept()
                with accepted:
                    accepted.settimeout(5)
                    before_pid = struct.unpack('i', client.getsockopt(0, 2, 4))[0]
                    before_token = client.getsockopt(0, 4, 32)
                    assert before_pid == os.getpid(), (mode, before_pid, os.getpid())
                    if mode in ['data', 'data-peer-closed']:
                        client.sendall(b'pending enrollment frame')
                    if mode.endswith('peer-closed'):
                        client.close()
                    descriptor = -1 if mode == 'negative-fd' else accepted.fileno()
                    child = subprocess.Popen([str(binary), str(descriptor), mode],
                        pass_fds=(accepted.fileno(),), stdin=subprocess.PIPE,
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                    try:
                        assert select.select([child.stdout], [], [], 10)[0], (mode, 'helper timeout')
                        value = json.loads(child.stdout.readline())
                        live = mode in ['idle', 'data', 'eintr-idle']
                        assert value['state'] == ('live' if live else 'refused'), (mode, value)
                        if live:
                            after_pid = struct.unpack('i', client.getsockopt(0, 2, 4))[0]
                            after_token = client.getsockopt(0, 4, 32)
                            assert after_pid == before_pid and after_token == before_token, \
                                (mode, 'inherited helper changed server peer identity',
                                 before_pid, after_pid, value['helperPID'])
                            if mode == 'data':
                                assert accepted.recv(1024) == b'pending enrollment frame'
                        else:
                            assert value['reason'] == 'peerUnavailable', (mode, value)
                        if mode.startswith('eintr-'):
                            assert value['pollCalls'] == 2, (mode, value)
                        print(json.dumps({'case': mode, 'passed': True,
                                          'serverPID': before_pid, **value}), flush=True)
                    finally:
                        _, error = child.communicate('\n', timeout=5)
                    assert child.returncode == 0, (mode, child.returncode, error)
    print('PASS 10 liveness cases using production source; peer identity and pending data preserved', flush=True)


with tempfile.TemporaryDirectory(prefix='provider-peer-anchor-') as temporary:
    check_liveness(Path(temporary))
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

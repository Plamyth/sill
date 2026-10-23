#!/usr/bin/env python3
"""생산 transport 메서드를 추출한다. 네트워크·listener·기기 실행은 없다."""
import argparse
import re
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
HOST = 'Sources/SillHost/StreamServer.swift'

def block(source, marker):
    start = source.index(marker)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

def generate(ref):
    manifest = {}
    def read(path):
        value = subprocess.check_output(['git', 'show', ref + ':' + path], cwd=ROOT, text=True) if ref else (ROOT/path).read_text()
        manifest[path] = hashlib.sha256(value.encode()).hexdigest()
        return value
    host = read(HOST)
    switcher = read('Sources/StreamProtocol/Switcher.swift')
    sentry = 'sentryAdmission' in host
    sentry_types = (read('Sources/StreamProtocol/Sentry.swift') + '\n' +
        read('Sources/SillHost/SentryAdmission.swift').replace('import StreamProtocol', '')) if sentry else ''
    message = read('Sources/StreamProtocol/StreamMessage.swift')
    admission = block(host, 'final class SourcePublicationAdmission:')
    client = block(host, 'private final class Client {')
    lane = block(host, 'private enum VideoLane:') if 'private enum VideoLane:' in host else ''
    peer = block(host, 'private final class PeerVideo {') if 'private final class PeerVideo {' in host else ''
    methods = ['resetForNewStream()', 'prepareVideo(', 'commitVideo(', 'resetLinks()',
               'send(each ', 'sendCatalog(', 'send(_ message:', 'broadcast(', 'paceRemote(',
               'remoteKeyframeDue(_ now: TimeInterval)', 'send(_ raw:', 'replayCatalog(',
               'sendMicrophoneCatalog(', 'sweep()', 'took(', 'setStreaming(', 'samplePointer(']
    methods += [x for x in ['enablePeerVideo(', 'resetPeerVideo(', 'preparePeerVideo(',
        'commitPeerVideo(', 'sendPeerVideo(', 'setPeerStreaming(', 'sendPeerCatalog(',
        'currentVideoAdmission(', 'catalogMatches(', 'requestKeyframe(for ',
        'remoteKeyframeDue(_ now: TimeInterval, for client:', 'noteKeyframeRequest(', 'setPeerPointerRect(',
        'deliverVideo(', 'isVideo(', 'hasStreamingClients', 'sendScopedMetadata('] if 'func ' + x in host]
    members = '\n'.join(('static ' if m == 'isVideo(' else '') + block(host, 'func ' + m) for m in methods)
    fixture = (HERE/'Fixture.swift').read_text()
    checks = (HERE/'Checks.swift').read_text()
    manifest['Tests/checks/peer-video-transport/Fixture.swift'] = hashlib.sha256(fixture.encode()).hexdigest()
    manifest['Tests/checks/peer-video-transport/Checks.swift'] = hashlib.sha256(checks.encode()).hexdigest()
    program = '\n'.join([message, sentry_types, switcher, admission, fixture.replace('// PRODUCTION_SENTRY', 'let sentryAdmission = SentryAdmission()' if sentry else '').replace('// PRODUCTION_TYPES', lane+'\n'+peer+'\n'+client).replace('// PRODUCTION_METHODS', members), checks])
    program = program.replace('// SENTRY_FLAG', '#if true' if sentry else '#if false')
    # Keep production bodies; only expose private members to this same-file I/O fixture.
    program = re.sub(r'\bprivate ', '', program)
    if lane: program = '#if true\n'+program.replace('// PEER_FLAG', '#if true')
    else: program = program.replace('// PEER_FLAG', '#if false')
    if lane: program += '\n#endif\n'
    return program, manifest

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ref')
    parser.add_argument('--emit', type=Path, required=True)
    args = parser.parse_args()
    program, manifest = generate(args.ref)
    args.emit.write_text(program)
    print(json.dumps({'ref': args.ref or 'working-tree', 'program_sha256': hashlib.sha256(program.encode()).hexdigest(), 'inputs': manifest}, sort_keys=True))

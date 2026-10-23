"""Execute real ingress/controller/mailbox policy with inert graph, network and main scheduler."""
from pathlib import Path
import hashlib
import os
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[3]
with tempfile.TemporaryDirectory(prefix='vision-review-') as temporary:
    output = Path(temporary)
    client = (root / 'iOSClient/StreamClient.swift').read_text()
    handle = client[client.index('    private func handle(_ header: StreamHeader, _ data: Data, from peer: NWConnection) {'):]
    body = handle[handle.index('        case .audio:') + len('        case .audio:'):handle.index('        case .remoteAudioState:')]
    controller = (root / 'visionOSClient/VisionAudioController.swift').read_text().replace('import AVFoundation\n', '')
    route = (root / 'visionOSClient/VisionAudioRoute.swift').read_text().replace('import Network\n', '').replace('import StreamProtocol\n', '')
    fixture = (root / 'Tests/checks/vision-voice-review/ingress.swift').read_text()
    if 'permitted:' not in controller:
        fixture = fixture.replace(', permitted: { allowed }', '')
    body = body.replace('DispatchQueue.main.async {', 'FixtureQueue.main.async {')
    controller = controller.replace('DispatchQueue.main.async {', 'FixtureQueue.main.async {')
    (output / 'Controller.swift').write_text(controller)
    (output / 'Route.swift').write_text(route)
    (output / 'main.swift').write_text(fixture + '\nextension StreamClient {\nfunc receiveAudio(_ data: Data, from peer: NWConnection) {\n' + body + '\n}\n}\n')
    print('extracted_audio_sha256', hashlib.sha256(body.encode()).hexdigest(), flush=True)
    sources = [root / 'visionOSClient/VisionAudioBuffer.swift', root / 'visionOSClient/VisionAudioState.swift',
               output / 'Controller.swift', output / 'Route.swift', output / 'main.swift']
    subprocess.run(['/usr/bin/xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', str(output / 'cache'),
                    *map(str, sources), '-o', str(output / 'checks')], check=True)
    subprocess.run([str(output / 'checks')], check=True)

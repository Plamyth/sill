"""기기 조작 없이 실제 xros SDK로 통합 제어 UI만 타입 검사한다."""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[3]
output = Path(sys.argv[1]).resolve()
output.mkdir(parents=True, exist_ok=True)
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
sdk = subprocess.check_output(['xcrun', '--sdk', 'xros', '--show-sdk-path'], env=env, text=True).strip()
wire = sorted((root / 'Sources/StreamProtocol').glob('*.swift'))
models = [root / 'visionOSClient' / (name + '.swift') for name in
          ['VisionProviderCall', 'VisionRemoteAudioIntent', 'VisionAudioForwarding']]
view = root / 'visionOSClient/SillVisionApp.swift'
chooser = root / 'visionOSClient/VisionMacAudioChooser.swift'
sources = wire + models + [view, chooser, root / 'visionOSClient/VisionAudioState.swift', root / 'iOSClient/IPadMicrophonePolicy.swift']
before = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
with tempfile.TemporaryDirectory(prefix='vision-call-sdk-') as temporary:
    scratch = Path(temporary)
    flags = ['xcrun', 'swiftc', '-swift-version', '5', '-sdk', sdk, '-target', 'arm64-apple-xros2.5',
             '-package-name', 'Sill', '-module-cache-path', str(scratch / 'cache')]
    pure = []
    for path in models:
        target = scratch / path.name
        target.write_text(path.read_text().split('#if os(visionOS)')[0])
        pure.append(target)
    text = view.read_text()
    controls = text[text.index('private struct VisionCallControls:'):text.index('private enum VisionConnectionCopy {')]
    ui = scratch / 'ControlsView.swift'
    ui.write_text('''import SwiftUI
import StreamProtocol
final class VisionAudioController: ObservableObject {
    @Published var presentation = VisionAudioState()
    @Published var cleanupProblem: String?
    func retryCleanup() {}
}
final class StreamClient: ObservableObject {
    @Published var visionProviderCall = VisionProviderCall(connection: UUID())
    var visionProviderCanStart = false
    var visionProviderCanStop = false
    var visionAudioIntentContext = VisionRemoteAudioIntent.Context()
    var visionForwarding: VisionAudioForwarding?
    var visionMicrophoneDesired = false
    var visionPlaybackDesired = false
    var microphonePhase = IPadMicrophonePolicy.Phase.off
    var microphoneCleanupProblem: String?
    var visionForwardingProblem: String?
    func performVisionProviderCall(_ action: ProviderCallRequest.Action) {}
    @discardableResult func setVisionAudioDesired(_ enabled: Bool, direction: VisionRemoteAudioIntent.Direction) -> Bool { false }
    func toggleVisionMicrophone() {}
}
''' + controls)
    commands = [
        flags + ['-emit-module', '-module-name', 'StreamProtocol', *map(str, wire),
                 '-emit-module-path', str(scratch / 'StreamProtocol.swiftmodule')],
        flags + ['-typecheck', '-I', str(scratch), *map(str, pure),
                 str(root / 'visionOSClient/VisionAudioState.swift'),
                 str(root / 'iOSClient/IPadMicrophonePolicy.swift'), str(ui)],
        flags + ['-parse', str(view), str(chooser), str(root / 'visionOSClient/VisionProviderCall.swift')],
    ]
    codes = []
    with (output / 'sdk.log').open('wb') as log:
        for command in commands:
            result = subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT)
            codes.append(result.returncode)
            if result.returncode:
                break
record = dict(sdk=sdk, exitCodes=codes, sourceSHA256=before,
              sourceUnchanged=all(hashlib.sha256((root / p).read_bytes()).hexdigest() == h for p, h in before.items()),
              scratchRemoved=not scratch.exists(), deviceCalls=0, mediaCalls=0, hostCoreConnections=0,
              scope='실제 xros SwiftUI 통합 제어 타입 검사. StreamClient와 audio controller는 실행하지 않는 stub. 앱 전체 타입 검사·빌드·서명·설치·착용 수용은 제외.')
(output / 'sdk.json').write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n')
print(json.dumps({k: v for k, v in record.items() if k != 'sourceSHA256'}, ensure_ascii=False))
raise SystemExit(0 if codes == [0, 0, 0] and record['sourceUnchanged'] and record['scratchRemoved'] else 1)

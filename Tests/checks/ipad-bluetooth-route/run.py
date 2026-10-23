"""실제 세션 소스의 경로 설정과 lease 복원을 가짜 AVAudioSession에서 검사한다."""
from pathlib import Path
import hashlib
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
paths = [root / 'iOSClient' / name for name in
         ['IPadAudioSession.swift', 'IPadAudioLeaseCoordinator.swift', 'IPadAudioLeaseState.swift']]
before = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
standin = '''import Foundation
final class AVAudioSession {
    enum Category { case ambient, playAndRecord, playback }
    enum Mode { case `default`, measurement }
    struct CategoryOptions: OptionSet {
        let rawValue: Int
        static let defaultToSpeaker = Self(rawValue: 1)
        static let mixWithOthers = Self(rawValue: 2)
        static let allowBluetoothHFP = Self(rawValue: 4)
        static let allowBluetoothA2DP = Self(rawValue: 8)
        static let duckOthers = Self(rawValue: 16)
    }
    struct SetActiveOptions: OptionSet {
        let rawValue: Int
        static let notifyOthersOnDeactivation = Self(rawValue: 1)
    }
    static let fixture = AVAudioSession()
    static func sharedInstance() -> AVAudioSession { fixture }
    var category = Category.ambient
    var mode = Mode.measurement
    var categoryOptions: CategoryOptions = [.duckOthers]
    var active = false
    var configurations = 0
    var deactivation: SetActiveOptions = []
    func setCategory(_ category: Category, mode: Mode, options: CategoryOptions) throws {
        self.category = category; self.mode = mode; self.categoryOptions = options
        configurations += 1
    }
    func setActive(_ active: Bool, options: SetActiveOptions = []) throws {
        self.active = active
        if !active { deactivation = options }
    }
}
'''
checks = '''import Foundation
var count = 0
func expect(_ condition: Bool, _ label: String) {
    count += 1; precondition(condition, label)
}
let native = AVAudioSession.sharedInstance(), owner = IPadAudioSession.shared
let microphone = UUID(), playback = UUID()
try owner.acquire(.microphoneUplink, leaseId: microphone)
expect(native.category == .playAndRecord && native.active, "microphone starts duplex session")
expect(native.categoryOptions.contains(.allowBluetoothHFP), "paired HFP microphone is eligible")
expect(native.categoryOptions.contains(.allowBluetoothA2DP), "paired A2DP output remains eligible")
expect(native.categoryOptions.contains([.defaultToSpeaker, .mixWithOthers]), "speaker and mixing preserved")
expect(owner.holds(leaseId: microphone), "original lease owns audio")
let configurations = native.configurations
try owner.acquire(.remotePlayback, leaseId: playback)
expect(native.configurations == configurations, "adding playback does not rebuild duplex category")
try owner.release(leaseId: microphone)
expect(native.category == .playback && native.active, "playback continues after mic off")
expect(!owner.holds(leaseId: microphone) && owner.holds(leaseId: playback), "only own mic lease released")
try owner.release(leaseId: playback)
expect(!native.active && native.deactivation == .notifyOthersOnDeactivation, "last lease deactivates politely")
expect(native.category == .ambient && native.mode == .measurement && native.categoryOptions == [.duckOthers], "previous configuration restored exactly")
expect(!owner.holds(leaseId: playback), "no remaining owner")
try owner.acquire(.remotePlayback, leaseId: playback)
expect(native.category == .playback, "playback-only category supported")
try owner.acquire(.microphoneUplink, leaseId: microphone)
expect(native.category == .playAndRecord && native.categoryOptions.contains([.allowBluetoothHFP, .allowBluetoothA2DP]), "duplex upgrade preserves bluetooth eligibility")
try owner.release(leaseId: playback)
expect(native.category == .playAndRecord && owner.holds(leaseId: microphone), "removing playback keeps microphone route")
try owner.release(leaseId: microphone)
expect(native.category == .ambient && !native.active, "second cycle restores original state")
print("PASS \\(count) actual-session configuration assertions; device/audio effects 0")
'''
with tempfile.TemporaryDirectory(prefix='ipad-bluetooth-route-') as temporary:
    out = Path(temporary)
    production = (root / 'iOSClient/IPadAudioSession.swift').read_text()
    assert production.count('import AVFoundation') == 1
    (out / 'Session.swift').write_text(standin + production.replace('import AVFoundation', ''))
    (out / 'main.swift').write_text(checks)
    binary = out / 'check'
    subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(out / 'cache'),
                    str(out / 'Session.swift'), str(paths[1]), str(paths[2]),
                    str(out / 'main.swift'), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
assert before == {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
print('SOURCE_UNCHANGED=true; SCRATCH_REMOVED=' + str(not out.exists()).lower())

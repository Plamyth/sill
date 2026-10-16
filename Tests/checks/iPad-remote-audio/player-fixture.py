from pathlib import Path
import sys

root, out = map(Path, sys.argv[1:])
source = (root / 'iOSClient/RemoteAudioPlayer.swift').read_text().split('\nprivate final class RemoteAACDecoder')[0]
source = source.replace('import AVFoundation\n', 'import Foundation\n').replace('final class RemoteAudioPlayer:', 'final class PlaybackProbe:')
start = source.index('    private func restart(')
brace = source.index('{', start)
depth, end = 1, brace + 1
while depth:
    depth += (source[end] == '{') - (source[end] == '}')
    end += 1
source = source[:brace + 1] + '''
        engine?.stop()
        engine = AVAudioEngine()
        ownsAudioSession = true
    }''' + source[end:]
end = source.rindex('}')
source = source[:end] + '''
    var buffered: Int { lock.withLock { samples.count - readIndex } }
    var currentEngine: AVAudioEngine? { engine }
    func drainDecode() { decodeQueue.sync {} }
''' + source[end:]
source += '''
final class AVAudioEngine {
    var stopped = false
    func stop() { stopped = true }
}
final class AVAudioSession {
    struct Options: OptionSet {
        let rawValue: Int
        static let notifyOthersOnDeactivation = Options(rawValue: 1)
    }
    static let shared = AVAudioSession()
    var releases = 0
    static func sharedInstance() -> AVAudioSession { shared }
    func setActive(_ active: Bool, options: Options) throws { if !active { releases += 1 } }
}
private final class RemoteAACDecoder {
    static var decoding: (() -> Void)?
    init?(rate: Double, channels: Int, cookie: Data) {}
    func matches(rate: Double, channels: Int, cookie: Data) -> Bool { true }
    func decode(_ packet: Data) -> [Float]? {
        Self.decoding?()
        return Array(repeating: 0.25, count: 2400)
    }
}
func holdAudioDecode(_ entered: DispatchSemaphore, _ release: DispatchSemaphore) {
    RemoteAACDecoder.decoding = { entered.signal(); release.wait() }
}
'''
(out / 'PlaybackFixture.swift').write_text(source)

from pathlib import Path
import sys

root, out = map(Path, sys.argv[1:])
source = (root / 'iOSClient/RemoteAudioPlayer.swift').read_text()
source = source.replace('final class RemoteAudioPlayer:', 'final class PlaybackProbe:')
source = source.replace('AVAudioEngine', 'FakeAudioEngine').replace('AVAudioSourceNode', 'FakeAudioSourceNode')
end = source.index('\nprivate final class RemoteAACDecoder')
source = source[:end] + "\n" + (Path(__file__).with_name('player-standins.swift')).read_text()
end = source.index('\nprivate final class RemoteAACDecoder')
close = source.rindex('}', 0, end)
source = source[:close] + '''
    var buffered: Int { lock.withLock { samples.count - readIndex } }
    var currentEngine: FakeAudioEngine? { engine }
    func drainDecode() { decodeQueue.sync {} }
    func receive(_ packet: Data) { receive(packet, subscription: UUID()) { _ in } }
''' + source[close:]
(out / 'PlaybackFixture.swift').write_text(source)

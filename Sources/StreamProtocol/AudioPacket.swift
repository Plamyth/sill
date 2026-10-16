import Foundation

/// One short audio packet on kind 33. The host and device negotiate whether the body is
/// interleaved 16-bit PCM or AAC-ELD. The high bit of the channels byte identifies AAC-ELD.
/// No audio is sent until the device explicitly subscribes on an authenticated Sill connection.
public enum AudioPacket {
    public static let aacELD = "aac-eld"

    public static func pack(sampleRate: UInt32, channels: UInt8, samples: UnsafeBufferPointer<Int16>) -> Data {
        var data = Data(capacity: 5 + samples.count * 2)
        data.appendBigEndian(sampleRate)
        data.append(channels)
        samples.withMemoryRebound(to: UInt8.self) { data.append(contentsOf: $0) }
        return data
    }

    public static func unpack(_ data: Data) -> (sampleRate: Double, channels: Int, samples: [Int16])? {
        guard data.count >= 5 else { return nil }
        let rate = data.readBigEndian(UInt32.self, at: 0)
        let channels = Int(data[data.startIndex + 4])
        let body = data.subdata(in: (data.startIndex + 5)..<data.endIndex)
        guard (8_000...192_000).contains(rate), (1...8).contains(channels),
              body.count % (2 * channels) == 0 else { return nil }
        return (Double(rate), channels, body.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) })
    }

    public static func packEncoded(sampleRate: UInt32, channels: UInt8, cookie: Data, packet: Data) -> Data {
        var data = Data(capacity: 6 + cookie.count + packet.count)
        data.appendBigEndian(sampleRate)
        data.append(channels | 0x80)
        data.append(UInt8(min(cookie.count, 255)))
        data.append(cookie.prefix(255))
        data.append(packet)
        return data
    }

    public static func unpackEncoded(_ data: Data) -> (sampleRate: Double, channels: Int, cookie: Data, packet: Data)? {
        guard data.count >= 6 else { return nil }
        let rate = data.readBigEndian(UInt32.self, at: 0)
        let flagged = data[data.startIndex + 4]
        guard flagged & 0x80 != 0 else { return nil }
        let channels = Int(flagged & 0x7F)
        let cookieLength = Int(data[data.startIndex + 5])
        guard (8_000...192_000).contains(rate), (1...8).contains(channels),
              data.count > 6 + cookieLength else { return nil }
        let start = data.startIndex + 6
        let cookie = data.subdata(in: start..<(start + cookieLength))
        return (Double(rate), channels, cookie, data.subdata(in: (start + cookieLength)..<data.endIndex))
    }
}

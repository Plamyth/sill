import Foundation
import StreamProtocol

class CALayer: NSObject {
    var frame = CGRect.zero
    var isHidden = false
    var backgroundColor: Int?
    var zPosition = 0.0
    func insertSublayer(_ layer: CALayer, at: UInt32) {}
    func removeFromSuperlayer() {}
}
final class FakeRenderer {
    static var flushes: [() -> Void] = []
    private(set) var samples = 0
    func enqueue(_ sample: CMSampleBuffer) { samples += 1 }
    func flush(removingDisplayedImage: Bool, completionHandler: (() -> Void)?) {
        if let completionHandler { Self.flushes.append(completionHandler) }
    }
    static func finish() {
        let pending = flushes
        flushes = []
        pending.forEach { $0() }
        drainMain()
    }
}
final class AVSampleBufferDisplayLayer: CALayer {
    enum Status { case unknown, rendering, failed }
    enum Gravity { case resizeAspect }
    var videoGravity = Gravity.resizeAspect
    var status = Status.unknown
    var error: Error?
    var isReadyForDisplay = false
    var requiresFlushToResumeDecoding = false
    let sampleBufferRenderer = FakeRenderer()
}
extension Notification.Name {
    static let AVSampleBufferDisplayLayerReadyForDisplayDidChange = Notification.Name("fake-ready")
    static let AVSampleBufferDisplayLayerFailedToDecode = Notification.Name("fake-failed")
    static let AVSampleBufferDisplayLayerRequiresFlushToResumeDecodingDidChange = Notification.Name("fake-flush")
}
struct CMVideoFormatDescription { let width: Int32; let height: Int32 }
struct FakeDimensions { let width: Int32; let height: Int32 }
enum FakeFormat {
    static var width: Int32 = 800
    static var height: Int32 = 600
    static var result: Int32 = 0
}
let noErr: Int32 = 0
func CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: Int?, parameterSetCount: Int,
    parameterSetPointers: [UnsafePointer<UInt8>], parameterSetSizes: [Int], nalUnitHeaderLength: Int32,
    extensions: Int?, formatDescriptionOut: inout CMVideoFormatDescription?) -> Int32 {
    formatDescriptionOut = CMVideoFormatDescription(width: FakeFormat.width, height: FakeFormat.height)
    return FakeFormat.result
}
func CMVideoFormatDescriptionGetDimensions(_ desc: CMVideoFormatDescription) -> FakeDimensions {
    FakeDimensions(width: desc.width, height: desc.height)
}
final class CMBlockBuffer {}
func CMBlockBufferCreateWithMemoryBlock(allocator: Int?, memoryBlock: UnsafeMutableRawPointer?, blockLength: Int,
    blockAllocator: Int?, customBlockSource: Int?, offsetToData: Int, dataLength: Int, flags: Int,
    blockBufferOut: inout CMBlockBuffer?) -> Int32 { blockBufferOut = CMBlockBuffer(); return noErr }
func CMBlockBufferAssureBlockMemory(_ block: CMBlockBuffer) -> Int32 { noErr }
func CMBlockBufferReplaceDataBytes(with: UnsafeRawPointer, blockBuffer: CMBlockBuffer,
    offsetIntoDestination: Int, dataLength: Int) -> Int32 { noErr }
enum FakeTime { case invalid }
struct CMSampleTimingInfo {
    let duration: FakeTime
    let presentationTimeStamp: FakeTime
    let decodeTimeStamp: FakeTime
}
final class CMSampleBuffer {}
func CMSampleBufferCreateReady(allocator: Int?, dataBuffer: CMBlockBuffer, formatDescription: CMVideoFormatDescription,
    sampleCount: Int, sampleTimingEntryCount: Int, sampleTimingArray: inout CMSampleTimingInfo,
    sampleSizeEntryCount: Int, sampleSizeArray: inout Int, sampleBufferOut: inout CMSampleBuffer?) -> Int32 {
    sampleBufferOut = CMSampleBuffer(); return noErr
}
let kCMSampleAttachmentKey_DisplayImmediately = "immediate"
func CMSampleBufferGetSampleAttachmentsArray(_ sample: CMSampleBuffer, createIfNecessary: Bool) -> NSArray? {
    [NSMutableDictionary()]
}
func drainMain() {
    let end = Date().addingTimeInterval(0.02)
    while Date() < end { _ = RunLoop.main.run(mode: .default, before: end) }
}

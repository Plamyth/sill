@_exported import Foundation
public protocol ObservableObject: AnyObject {}
@propertyWrapper public struct Published<Value> {
    public var wrappedValue: Value
    public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}

public struct SpatialEventCollection {
    public struct Event {
        public enum Kind { case directPinch, indirectPinch, touch, pointer }
        public enum Phase { case active, ended, cancelled }
        public let id: Int
        public let timestamp: TimeInterval
        public let kind: Kind
        public let location: CGPoint
        public let phase: Phase
        public init(id: Int, timestamp: TimeInterval, kind: Kind, location: CGPoint, phase: Phase) {
            self.id = id; self.timestamp = timestamp; self.kind = kind; self.location = location; self.phase = phase
        }
    }
}

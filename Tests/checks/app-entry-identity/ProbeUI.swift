@_exported import Foundation

public enum EntryProbe {
    public static var content = 0
    public static var workspace = 0
    public static var errors: [String] = []
}

public protocol View {}
public struct ProbeView: View {}
@resultBuilder public enum ViewBuilder {
    public static func buildBlock<V: View>(_ value: V) -> ProbeView { ProbeView() }
    public static func buildBlock() -> ProbeView { ProbeView() }
    public static func buildEither(first: ProbeView) -> ProbeView { ProbeView() }
    public static func buildEither(second: ProbeView) -> ProbeView { ProbeView() }
    public static func buildOptional(_ value: ProbeView?) -> ProbeView { ProbeView() }
}
public protocol Scene {}
public struct WindowGroup<V: View>: Scene {
    public init(@ViewBuilder content: () -> V) { _ = content() }
}
public protocol App {
    associatedtype Body: Scene
    init()
    var body: Body { get }
}
public extension App {
    static func main() {
        _ = Self().body
        let expected = ProcessInfo.processInfo.environment["ENTRY_EXPECTED"]!
        let actual = EntryProbe.content == 1 ? "normal" : EntryProbe.workspace == 1 ? "isolated" : "blocked"
        precondition(actual == expected, "expected \(expected), got \(actual)")
        precondition(EntryProbe.content + EntryProbe.workspace <= 1, "multiple entry paths")
        precondition(!EntryProbe.errors.contains("canvasTestRuntimeReceiptError"), "receipt failed")
        if actual == "blocked" {
            precondition(EntryProbe.errors.contains("sillAppIdentityError") ||
                         EntryProbe.errors.contains("canvasTestRuntimeError"), "missing error")
        }
        print("PASS entry=\(actual) content=\(EntryProbe.content) workspace=\(EntryProbe.workspace) errors=\(EntryProbe.errors)")
    }
}
@propertyWrapper public final class State<Value> {
    public var wrappedValue: Value
    public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
@propertyWrapper public struct UIApplicationDelegateAdaptor<Value> {
    public var wrappedValue: Value { fatalError("delegate is not accessed in this boundary probe") }
    public init(_ type: Value.Type) {}
}
public struct Text: View {
    public init(_ value: String) {}
}
public enum Alignment { case top }
public extension View {
    func padding() -> Self { self }
    func accessibilityIdentifier(_ value: String) -> Self {
        EntryProbe.errors.append(value)
        return self
    }
    func onAppear(_ action: () -> Void) -> Self { action(); return self }
    func overlay<V: View>(alignment: Alignment, @ViewBuilder content: () -> V) -> Self {
        _ = content()
        return self
    }
}

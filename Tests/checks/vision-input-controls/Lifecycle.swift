import Foundation
import SwiftUI

struct GestureValue {
    struct Magnification {
        let magnification: CGFloat
        let startLocation: CGPoint
        let time: Date
    }
    var first: [SpatialEventCollection.Event]?
    var second: Magnification?
}

final class CallbackState {
    var revision: UUID?
    var admitted = true
    var admissions = 0
}

private func deliver<T>(_ value: T, _ callback: (T) -> Void) { callback(value) }
private func deliver<T>(_ old: T, _ value: T, _ callback: (T, T) -> Void) { callback(old, value) }
private func deliver(_ callback: () -> Void) { callback() }

final class SpatialCallbacks {
    let input: VisionInputSession
    let geometry: VisionPointer.Geometry
    let state: CallbackState
    var revision: UUID? {
        get { state.revision }
        set { state.revision = newValue }
    }

    init(input: VisionInputSession, geometry: VisionPointer.Geometry, state: CallbackState) {
        self.input = input
        self.geometry = geometry
        self.state = state
    }

    func admit(_ action: () -> Void) {
        state.admissions += 1
        if state.admitted { action() }
    }

    func changed(_ value: GestureValue) { deliver(value, CALLBACK_CHANGED) }
    func ended(_ value: GestureValue) { deliver(value, CALLBACK_ENDED) }
    func recognizingChanged(_ active: Bool) { deliver(false, active, CALLBACK_RECOGNIZING) }
    func geometryChanged(_ value: VisionPointer.Geometry) { deliver(geometry, value, CALLBACK_GEOMETRY) }
    func disappeared() { deliver(CALLBACK_DISAPPEAR) }
}

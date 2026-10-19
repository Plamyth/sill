import SwiftUI

extension VisionPointer.Sample {
    init?(_ event: SpatialEventCollection.Event) {
        switch event.kind {
        case .directPinch, .indirectPinch, .touch: break
        default: return nil
        }
        let phase: Phase
        switch event.phase {
        case .active: phase = .active
        case .ended: phase = .ended
        case .cancelled: phase = .cancelled
        @unknown default: phase = .cancelled
        }
        self.init(id: AnyHashable(event.id), timestamp: event.timestamp, location: event.location, phase: phase)
    }
}

struct VisionSpatialInput: View {
    @ObservedObject var input: VisionInputSession
    let geometry: VisionPointer.Geometry
    let admit: (() -> Void) -> Void
    @GestureState private var recognizing = false
    @State private var revision: UUID?

    var body: some View {
        Color.clear.contentShape(Rectangle())
            .accessibilityLabel("Mac 원격 화면")
            .accessibilityHint("바라보고 짧게 집으면 클릭합니다. 집은 채 바로 움직이면 스크롤하고, 빠르게 움직여 놓으면 자연스럽게 감속합니다. 길게 집었다 놓으면 오른쪽 클릭, 길게 집은 뒤 움직이면 드래그합니다. 두 손 집기로 이 화면을 확대하거나 축소합니다.")
            .gesture(SpatialEventGesture(coordinateSpace: .local)
                .simultaneously(with: MagnifyGesture())
                .updating($recognizing) { _, state, _ in state = true }
                .onChanged { value in
                    let ticket = revision ?? input.gestureRevision
                    revision = ticket
                    admit {
                        if let zoom = value.second {
                            input.magnify(zoom.magnification, at: zoom.startLocation, time: zoom.time.timeIntervalSinceReferenceDate,
                                          geometry: geometry, revision: ticket)
                        }
                        if let contacts = value.first {
                            input.spatial(contacts.compactMap { VisionPointer.Sample($0) }, geometry: geometry, revision: ticket)
                        }
                    }
                }
                .onEnded { value in
                    guard let ticket = revision else { return }
                    admit {
                        if let zoom = value.second {
                            input.magnify(zoom.magnification, at: zoom.startLocation, time: zoom.time.timeIntervalSinceReferenceDate,
                                          geometry: geometry, revision: ticket)
                        }
                        if let contacts = value.first {
                            input.spatial(contacts.compactMap { VisionPointer.Sample($0) }, geometry: geometry, revision: ticket)
                        }
                        input.finishGesture(revision: ticket, allowMomentum: true)
                    }
                    revision = nil
                })
            .onChange(of: recognizing) { _, active in
                if !active, let ticket = revision {
                    admit { input.finishGesture(revision: ticket) }
                    revision = nil
                }
            }
            .onChange(of: geometry, initial: true) { _, value in admit { input.setGeometry(value) } }
            .onDisappear {
                admit {
                    input.stopMomentum()
                    if let ticket = revision { input.finishGesture(revision: ticket) }
                }
                revision = nil
            }
    }
}

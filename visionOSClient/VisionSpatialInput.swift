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
            .hoverEffect(.highlight, isEnabled: input.canSend)
            .accessibilityLabel("Mac 원격 화면")
            .accessibilityHint("바라보고 한 번 집으면 클릭, 빠르게 두 번 집으면 더블클릭합니다. 집고 유지했다 놓으면 오른쪽 클릭, 집은 채 움직이면 가로와 세로로 스크롤합니다. 두 손을 벌리거나 모으면 확대하거나 축소합니다. 두 손을 오른쪽이나 왼쪽으로 돌렸다 놓으면 Mac 데스크탑을 한 칸 전환합니다.")
            .gesture(SpatialEventGesture(coordinateSpace: .local)
                .simultaneously(with: MagnifyGesture().simultaneously(with: RotateGesture()))
                .updating($recognizing) { _, state, _ in state = true }
                .onChanged { value in
                    let ticket = revision ?? input.gestureRevision
                    revision = ticket
                    admit {
                        if let turn = value.second?.second {
                            input.rotate(turn.rotation.degrees, at: turn.startLocation, time: turn.time.timeIntervalSinceReferenceDate,
                                         geometry: geometry, revision: ticket)
                        }
                        if let zoom = value.second?.first {
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
                        if let turn = value.second?.second {
                            input.rotate(turn.rotation.degrees, at: turn.startLocation, time: turn.time.timeIntervalSinceReferenceDate,
                                         geometry: geometry, revision: ticket)
                        }
                        if let zoom = value.second?.first {
                            input.magnify(zoom.magnification, at: zoom.startLocation, time: zoom.time.timeIntervalSinceReferenceDate,
                                          geometry: geometry, revision: ticket)
                        }
                        if let contacts = value.first {
                            input.spatial(contacts.compactMap { VisionPointer.Sample($0) }, geometry: geometry, revision: ticket)
                        }
                        input.finishGesture(revision: ticket, completed: true)
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

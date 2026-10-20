#if DEBUG
import PencilKit
import SwiftUI
import UIKit

@MainActor
enum CanvasModeLifetimeChecks {
    @MainActor
    private final class InkEdit {
        let canvas: CanvasInkView
        let coordinator: PencilCanvas.Coordinator

        init(canvas: CanvasInkView, coordinator: PencilCanvas.Coordinator) {
            self.canvas = canvas
            self.coordinator = coordinator
        }

        func restore(_ drawing: PKDrawing) {
            let previous = canvas.drawing
            canvas.inkUndoManager.registerUndo(withTarget:self) { $0.restore(previous) }
            canvas.drawing = drawing
            coordinator.canvasViewDrawingDidChange(canvas)
        }

        func edit(_ drawing: PKDrawing) {
            canvas.inkUndoManager.beginUndoGrouping()
            restore(drawing)
            canvas.inkUndoManager.endUndoGrouping()
        }
    }

    static func run(host: UIHostingController<AnyView>) async throws -> String {
        guard case .isolated = CanvasRuntime.launch else { throw CocoaError(.fileWriteNoPermission) }
        func descendants(_ view: UIView) -> [UIView] {
            [view] + view.subviews.flatMap(descendants)
        }
        func settle() async throws {
            try await Task.sleep(for:.milliseconds(150))
            host.view.layoutIfNeeded()
        }
        try await settle()
        let views = descendants(host.view)
        guard let canvas = views.compactMap({ $0 as? CanvasInkView }).first,
              let coordinator = canvas.delegate as? PencilCanvas.Coordinator,
              let picker = views.compactMap({ $0 as? UISegmentedControl }).first,
              let window = host.view.window, picker.numberOfSegments == 3 else {
            throw CocoaError(.coderValueNotFound)
        }
        let store = coordinator.store
        let manager = canvas.inkUndoManager
        manager.groupsByEvent = false
        let fixture = InkEdit(canvas:canvas,coordinator:coordinator)
        let before = canvas.drawing
        let stroke = PKStroke(ink:PKInk(.pen,color:CanvasPalette.ink),path:PKStrokePath(controlPoints:[
            PKStrokePoint(location:CGPoint(x:30,y:40),timeOffset:0,size:CGSize(width:4,height:4),
                opacity:1,force:1,azimuth:0,altitude:1),
            PKStrokePoint(location:CGPoint(x:160,y:40),timeOffset:0.1,size:CGSize(width:4,height:4),
                opacity:1,force:1,azimuth:0,altitude:1)
        ],creationDate:Date(timeIntervalSince1970:1)))
        let after = PKDrawing(strokes:before.strokes + [stroke])
        fixture.edit(after)
        store.viewport = CanvasViewport(zoom:1.4,pan:CGSize(width:23,height:31))
        try await settle()
        let generation = store.inkHistory.generation
        let viewport = store.viewport
        let nodes = store.scene.nodes
        var checks = 0
        func check(_ value: Bool, _ label: String) throws {
            checks += 1
            print("\(value ? "PASS" : "FAIL") \(label)")
            guard value else {
                throw NSError(domain:"CanvasModeLifetimeChecks",code:checks,
                    userInfo:[NSLocalizedDescriptionKey:label])
            }
        }
        try check(manager.canUndo && store.inkHistory.availability.canUndo,"전환 전 제어된 잉크 Undo 등록")
        var undone = false
        for mode in [1,2,0,2,1,0] {
            picker.selectedSegmentIndex = mode
            picker.sendActions(for:.valueChanged)
            try await settle()
            let canvases = descendants(host.view).compactMap { $0 as? CanvasInkView }
            try check(canvases.count == 1 && canvases[0] === canvas && canvas.delegate === coordinator &&
                canvas.undoManager === manager && store.inkHistory.generation == generation,
                "보기 \(mode) 전환에서 실제 PKCanvasView·Coordinator·UndoManager 동일성 유지")
            try check(store.viewport == viewport && store.scene.nodes == nodes,
                "보기 \(mode) 전환에서 뷰포트·줌·노드 좌표 유지")
            try check(canvas.superview?.accessibilityElementsHidden == (mode == 1) &&
                canvas.superview?.isAccessibilityElement == (mode != 1) &&
                canvas.superview?.isHidden == (mode == 1) &&
                canvas.superview?.isUserInteractionEnabled == (mode != 1),
                "보기 \(mode)에서 원본 UIKit 입력·접근성 노출이 표시 상태와 일치")
            if mode == 1 {
                let hit = window.hitTest(canvas.convert(CGPoint(x:100,y:100),to:window),with:nil)
                try check(hit !== canvas && hit?.isDescendant(of:canvas) != true,
                    "숨겨진 원본 캔버스가 터치 입력을 받지 않음")
            }
            if undone { store.inkHistory.redo() }
            else { store.inkHistory.undo() }
            undone.toggle()
            try await settle()
            try check(canvas.drawing == (undone ? before : after) &&
                store.drawing == canvas.drawing &&
                (undone ? store.inkHistory.availability.canRedo : store.inkHistory.availability.canUndo),
                "보기 \(mode)에서도 기존 Undo·Redo가 실제 그림에 반영")
        }
        store.scene.id = UUID()
        try await settle()
        try check(store.inkHistory.generation != generation && !manager.canUndo && !manager.canRedo,
            "실제 scene 교체에서는 이전 잉크 이력 무효화 유지")
        fixture.edit(before)
        try await settle()
        try check(manager.canUndo,"실제 해제 전 새 잉크 이력 등록")
        host.rootView = AnyView(EmptyView())
        try await settle()
        try check(canvas.delegate == nil && coordinator.canvas == nil && !manager.canUndo && !manager.canRedo,
            "진짜 뷰 해제에서는 dismantle·detach와 Undo 정리 유지")
        return "CANVAS_MODE_LIFETIME total=\(checks) failed=0 controlledRegistrations=true pencilInputExecuted=false"
    }
}

#if CANVAS_MODE_LIFETIME_CHECK
@main
struct CanvasModeLifetimeProbeApp: App {
    var body: some Scene { WindowGroup { CanvasModeLifetimeProbe() } }
}

private struct CanvasModeLifetimeProbe: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIHostingController<AnyView> {
        guard case .isolated = CanvasRuntime.launch else {
            return UIHostingController(rootView:AnyView(Text("FAIL 격리 runtime이 필요합니다.")
                .accessibilityIdentifier("canvasModeLifetimeResult")))
        }
        let host = UIHostingController(rootView:AnyView(CanvasWorkspace()))
        Task { @MainActor in
            do {
                let result = try await CanvasModeLifetimeChecks.run(host:host)
                print(result)
                host.rootView = AnyView(Text(result).accessibilityIdentifier("canvasModeLifetimeResult"))
            } catch {
                let result = "FAIL \(error.localizedDescription)"
                print(result)
                host.rootView = AnyView(Text(result).accessibilityIdentifier("canvasModeLifetimeResult"))
            }
        }
        return host
    }

    func updateUIViewController(_ host: UIHostingController<AnyView>, context: Context) { }
}
#endif
#endif

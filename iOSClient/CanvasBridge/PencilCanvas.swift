import PencilKit
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

final class CanvasNativeUndoManager: UndoManager {
    weak var history: CanvasInkHistory?
    override var canUndo: Bool { MainActor.assumeIsolated { history?.commandAvailability.canUndo == true } }
    override var canRedo: Bool { MainActor.assumeIsolated { history?.commandAvailability.canRedo == true } }
    override func undo() { MainActor.assumeIsolated { history?.undo() } }
    override func redo() { MainActor.assumeIsolated { history?.redo() } }
    override func undoNestedGroup() { MainActor.assumeIsolated { history?.undo() } }
}

final class CanvasInkView: PKCanvasView {
    var inkUndoManager = UndoManager()
    let nativeUndoManager = CanvasNativeUndoManager()
    override var undoManager: UndoManager? { nativeUndoManager }
}

@MainActor
private enum CanvasDrawingHistory {
    static func register(_ previous: PKDrawing, store: CanvasStore, manager: UndoManager,
                         owner: CanvasInkHistory.Owner, generation: UUID) {
        let needsGroup = manager.groupingLevel == 0 && !manager.isUndoing && !manager.isRedoing
        if needsGroup { manager.beginUndoGrouping() }
        manager.registerUndo(withTarget:store) { [weak manager] target in
            MainActor.assumeIsolated {
                guard let manager, target.nativeHistoryOwner == owner,
                      target.inkHistory.generation == generation else { return }
                let current = target.drawing
                guard current != previous, target.updateDrawing(previous) else { return }
                register(current,store:target,manager:manager,owner:owner,generation:generation)
                target.inkHistory.scheduleRefresh()
            }
        }
        if needsGroup { manager.endUndoGrouping() }
    }
}

struct PencilCanvas: UIViewRepresentable {
    @ObservedObject var store: CanvasStore
    var isVisible = true

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        host.backgroundColor = CanvasPalette.background

        let canvas = CanvasInkView(frame: host.bounds)
        canvas.overrideUserInterfaceStyle = .light
        canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvas.delegate = context.coordinator
        canvas.backgroundColor = CanvasPalette.background
        canvas.isOpaque = true
        canvas.drawingPolicy = .pencilOnly
        canvas.isScrollEnabled = false
        canvas.minimumZoomScale = 1
        canvas.maximumZoomScale = 1
        canvas.tool = store.penTool
        canvas.addInteraction(UIPencilInteraction(delegate: context.coordinator))
        host.addSubview(canvas)

        let overlay = PencilPreviewView(frame: host.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.backgroundColor = .clear
        overlay.isUserInteractionEnabled = false
        host.addSubview(overlay)

        let layer = context.coordinator.previewLayer
        layer.fillColor = nil
        layer.strokeColor = store.penTool.color.cgColor
        layer.lineWidth = store.penTool.width
        layer.lineCap = .round
        layer.lineJoin = .round
        overlay.previewLayer = layer
        overlay.layer.addSublayer(layer)

        let hoverLayer = context.coordinator.hoverLayer
        hoverLayer.fillColor = store.penTool.color.withAlphaComponent(0.4).cgColor
        hoverLayer.strokeColor = store.penTool.color.cgColor
        hoverLayer.lineWidth = 2
        hoverLayer.isHidden = true
        overlay.layer.addSublayer(hoverLayer)

        context.coordinator.canvas = canvas
        canvas.isRulerActive = store.rulerIsActive(isVisible: isVisible)
        canvas.inkUndoManager = store.inkHistory.activate(store.nativeHistoryOwner)
        context.coordinator.replaceDrawingFromStore()

        let trace = PencilTraceRecognizer()
        trace.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        trace.cancelsTouchesInView = false
        trace.delaysTouchesBegan = false
        trace.delegate = context.coordinator
        trace.onSample = { [weak coordinator = context.coordinator] point, phase in
            coordinator?.sample(point, phase: phase)
        }
        host.addGestureRecognizer(trace)

        let hover = UIHoverGestureRecognizer(target: context.coordinator,
                                              action: #selector(Coordinator.hoverCanvas(_:)))
        hover.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        canvas.addGestureRecognizer(hover)

        let finger = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.panCanvas(_:)))
        pan.allowedTouchTypes = finger
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = false
        pan.delegate = context.coordinator
        host.addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.pinchCanvas(_:)))
        pinch.allowedTouchTypes = finger
        pinch.cancelsTouchesInView = false
        pinch.delegate = context.coordinator
        host.addGestureRecognizer(pinch)
        host.isAccessibilityElement = isVisible
        host.accessibilityElementsHidden = !isVisible
        host.isHidden = !isVisible
        host.accessibilityLabel = "캔버스 이동과 확대"
        host.accessibilityIdentifier = "canvasNavigationSurface"
        return host
    }

    func updateUIView(_ host: UIView, context: Context) {
        guard let canvas = context.coordinator.canvas else { return }
        host.isAccessibilityElement = isVisible
        host.accessibilityElementsHidden = !isVisible
        host.isHidden = !isVisible
        host.isUserInteractionEnabled = isVisible
        host.accessibilityValue = "확대 \(Int(store.zoom * 100))%"
        if context.coordinator.renderedOwner != store.nativeHistoryOwner || context.coordinator.renderedGeneration != store.inkHistory.generation ||
           context.coordinator.renderedModelDrawing != store.drawing ||
           context.coordinator.renderedDocument.map(store.document.matchesPageActivation) != true {
            context.coordinator.replaceDrawingFromStore()
        }
        canvas.isUserInteractionEnabled = store.mode != .select && !store.documentBusy
        canvas.isRulerActive = store.rulerIsActive(isVisible: isVisible)
        if !store.inkBusy {
            switch store.mode {
            case .pen: canvas.tool = store.penTool
            case .eraser: canvas.tool = store.eraserTool
            case .lasso: canvas.tool = PKLassoTool()
            case .select: break
            }
        }
        if canvas.selection != store.inkSelection { canvas.selection = store.inkSelection }
        context.coordinator.previewLayer.isHidden = canvas.isRulerActive ||
            (store.mode == .eraser && store.eraserPreviewWidth == nil)
        context.coordinator.previewLayer.lineWidth = store.mode == .eraser ? (store.eraserPreviewWidth ?? 4) : store.penTool.width
        context.coordinator.updateHover()
    }

    static func dismantleUIView(_ host: UIView, coordinator: Coordinator) {
        guard let canvas = coordinator.canvas else { coordinator.retire(); return }
        canvas.isRulerActive = false
        canvas.delegate = nil
        coordinator.flushPendingDrawing(save:true)
        coordinator.retire()
        if !coordinator.store.isDocumentSource { coordinator.store.inkHistory.detach(canvas.inkUndoManager) }
        coordinator.canvas = nil
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate, UIPencilInteractionDelegate,
                             UIGestureRecognizerDelegate {
        let store: CanvasStore
        let traceOwner = UUID()
        weak var canvas: CanvasInkView? {
            didSet {
                oldValue?.nativeUndoManager.history = nil
                canvas?.nativeUndoManager.history = store.inkHistory
            }
        }
        var renderedModelDrawing = PKDrawing()
        var renderedGeneration = UUID()
        var renderedOwner: CanvasInkHistory.Owner?
        var renderedDocument: CanvasDocument.PageSnapshot?
        private var replacingDrawing = false
        let previewLayer = CAShapeLayer()
        let hoverLayer = CAShapeLayer()
        private var previewPath = UIBezierPath()
        private var previewSession = 0
        private var hoverPoint: CGPoint?
        private var isDrawing = false
        private var usingTool = false
        private var backgroundObserver: NSObjectProtocol?
        private var drawingChangeSerial = 0
        private var retired = false
        private var activation = UUID()
        private var toolActivation: UUID?
        private var traceActivation: UUID?
        private var panActivation: UUID?
        private var pinchActivation: UUID?
        private var panStart = CanvasViewport()
        private var pinchStart = CanvasViewport()
        private var pinchAnchor = CGPoint.zero
        private var pinchCenter = CGPoint.zero

        init(store: CanvasStore) {
            self.store = store
            super.init()
            backgroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.flushPendingDrawing(save: true) }
            }
        }

        deinit {
            if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        }

        private var liveInput: Bool {
            !retired && canvas != nil && renderedOwner == store.nativeHistoryOwner &&
                renderedGeneration == store.inkHistory.generation && renderedDocument.map(store.document.matchesPageActivation) == true
        }

        private func currentCanvas(_ view: PKCanvasView) -> Bool { liveInput && canvas === view }

        private func currentGesture(_ gesture: UIGestureRecognizer) -> Bool {
            guard liveInput, let host = canvas?.superview, let view = gesture.view else { return false }
            return view === host || view.isDescendant(of:host)
        }

        fileprivate func retire() {
            guard !retired else { return }
            retired = true
            activation = UUID(); drawingChangeSerial += 1; previewSession += 1
            toolActivation = nil; traceActivation = nil; panActivation = nil; pinchActivation = nil
            isDrawing = false; usingTool = false; hoverPoint = nil
            previewLayer.path = nil; hoverLayer.isHidden = true
            if renderedOwner == store.nativeHistoryOwner, renderedGeneration == store.inkHistory.generation {
                store.inkHistory.setUsingTool(false,owner:traceOwner)
            }
            store.setPencilTraceActive(false,owner:traceOwner)
        }

        func replaceDrawingFromStore() {
            guard !retired else { return }
            if let canvas { canvas.inkUndoManager = store.inkHistory.activate(store.nativeHistoryOwner) }
            restoreDrawingFromStore()
        }

        private func restoreDrawingFromStore() {
            guard !retired, let canvas else { return }
            replacingDrawing = true
            activation = UUID()
            toolActivation = nil; traceActivation = nil; panActivation = nil; pinchActivation = nil
            drawingChangeSerial += 1
            let manager = canvas.nativeUndoManager
            manager.disableUndoRegistration()
            let enabled = canvas.drawingGestureRecognizer.isEnabled
            canvas.drawingGestureRecognizer.isEnabled = false
            canvas.drawing = store.drawing
            canvas.selection = store.inkSelection
            canvas.drawingGestureRecognizer.isEnabled = enabled
            manager.enableUndoRegistration()
            manager.removeAllActions()
            renderedModelDrawing = store.drawing
            renderedGeneration = store.inkHistory.generation
            renderedOwner = store.nativeHistoryOwner
            renderedDocument = try? store.document.pageSnapshot()
            isDrawing = false
            usingTool = false
            store.inkHistory.setUsingTool(false,owner:traceOwner)
            store.setPencilTraceActive(false, owner: traceOwner)
            previewSession += 1
            previewLayer.path = nil
            replacingDrawing = false
            store.inkHistory.scheduleRefresh()
        }

        private func registerDrawingUndo(_ previous: PKDrawing) {
            guard let canvas else { return }
            CanvasDrawingHistory.register(previous,store:store,manager:canvas.inkUndoManager,
                owner:store.nativeHistoryOwner,generation:renderedGeneration)
        }

        private func commitDrawing(_ drawing: PKDrawing) {
            let previous = store.drawing
            guard store.updateDrawing(drawing) else {
                restoreDrawingFromStore()
                return
            }
            if previous != drawing { registerDrawingUndo(previous) }
            renderedModelDrawing = store.drawing
            renderedDocument = try? store.document.pageSnapshot()
        }

        fileprivate func sample(_ point: CGPoint, phase: PencilTraceRecognizer.Phase) {
            guard liveInput else { return }
            switch phase {
            case .began:
                traceActivation = activation
                isDrawing = true
                store.setPencilTraceActive(true, owner: traceOwner)
                hoverLayer.isHidden = true
                previewSession += 1
                previewPath = UIBezierPath()
                previewPath.move(to: point)
                previewLayer.strokeColor = store.mode == .eraser ?
                    UIColor.systemRed.withAlphaComponent(0.7).cgColor : store.penTool.color.cgColor
                previewLayer.isHidden = canvas?.isRulerActive == true ||
                    (store.mode == .eraser && store.eraserPreviewWidth == nil)
                previewLayer.lineWidth = store.mode == .eraser ? (store.eraserPreviewWidth ?? 4) : store.penTool.width
            case .moved:
                guard traceActivation == activation else { return }
                previewPath.addLine(to: point)
                previewLayer.path = previewPath.cgPath
            case .ended:
                guard traceActivation == activation else { return }
                traceActivation = nil
                isDrawing = false
                store.setPencilTraceActive(false, owner: traceOwner)
                hoverPoint = point
                updateHover()
                let session = previewSession
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    guard let self, !self.retired, self.previewSession == session else { return }
                    self.previewLayer.path = nil
                }
            }
        }

        @objc fileprivate func hoverCanvas(_ gesture: UIHoverGestureRecognizer) {
            guard currentGesture(gesture) else { return }
            switch gesture.state {
            case .began, .changed:
                guard !isDrawing else { return }
                hoverPoint = gesture.location(in: gesture.view)
                updateHover()
            default:
                hoverPoint = nil
                hoverLayer.isHidden = true
            }
        }

        fileprivate func updateHover() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            guard liveInput, !isDrawing, let hoverPoint, store.mode == .pen || store.mode == .eraser,
                  store.mode != .eraser || store.eraserPreviewWidth != nil else {
                hoverLayer.isHidden = true
                return
            }
            let erasing = store.mode == .eraser
            let diameter: CGFloat = erasing ? (store.eraserPreviewWidth ?? 8) : max(8, store.penTool.width * 2)
            hoverLayer.path = UIBezierPath(ovalIn:CGRect(x:-diameter / 2,y:-diameter / 2,
                                                          width:diameter,height:diameter)).cgPath
            hoverLayer.position = hoverPoint
            hoverLayer.fillColor = erasing ? UIColor.clear.cgColor :
                store.penTool.color.withAlphaComponent(0.4).cgColor
            hoverLayer.strokeColor = erasing ? UIColor.systemRed.cgColor : store.penTool.color.cgColor
            hoverLayer.isHidden = false
        }

        @objc fileprivate func panCanvas(_ gesture: UIPanGestureRecognizer) {
            guard currentGesture(gesture) else { return }
            switch gesture.state {
            case .began: panStart = store.viewport; panActivation = activation
            case .changed, .ended:
                guard panActivation == activation else { return }
                let shift = gesture.translation(in:nil)
                store.viewport = panStart.translated(by: CGSize(width:shift.x,height:shift.y))
                if gesture.state == .ended { panActivation = nil }
            default: panActivation = nil
            }
        }

        @objc fileprivate func pinchCanvas(_ gesture: UIPinchGestureRecognizer) {
            guard currentGesture(gesture) else { return }
            switch gesture.state {
            case .began:
                pinchActivation = activation
                pinchStart = store.viewport
                pinchAnchor = gesture.location(in:gesture.view)
                pinchCenter = gesture.location(in:nil)
            case .changed, .ended:
                guard pinchActivation == activation else { return }
                let center = gesture.location(in:nil)
                store.viewport = pinchStart.scaled(by:Double(gesture.scale),around:pinchAnchor,
                    centerShift:CGSize(width:center.x-pinchCenter.x,height:center.y-pinchCenter.y))
                if gesture.state == .ended { pinchActivation = nil }
            default: pinchActivation = nil
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard currentGesture(gestureRecognizer) else { return false }
            if canvas?.isRulerActive == true,
               gestureRecognizer is UIPanGestureRecognizer || gestureRecognizer is UIPinchGestureRecognizer {
                return false
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            currentGesture(gestureRecognizer) && currentGesture(otherGestureRecognizer)
        }

        func canvasViewSelectionDidChange(_ canvasView: PKCanvasView) {
            guard !replacingDrawing, currentCanvas(canvasView) else { return }
            store.setInkSelection(canvasView.selection)
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !replacingDrawing, currentCanvas(canvasView) else { return }
            drawingChangeSerial += 1
            guard !usingTool else { return }
            let serial = drawingChangeSerial
            let generation = renderedGeneration
            let active = activation
            let drawing = canvasView.drawing, owner = renderedOwner
            let snapshot = renderedDocument
            Task { @MainActor [weak self, weak canvasView] in
                guard let self, let canvasView, self.currentCanvas(canvasView), self.activation == active,
                      self.drawingChangeSerial == serial, self.store.nativeHistoryOwner == owner,
                      snapshot.map(self.store.document.accepts) == true,
                      self.store.inkHistory.generation == generation else { return }
                self.commitDrawing(drawing)
                self.store.inkHistory.scheduleRefresh()
            }
        }

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            guard !replacingDrawing, currentCanvas(canvasView) else { return }
            drawingChangeSerial += 1
            toolActivation = activation
            usingTool = true
            store.inkHistory.setUsingTool(true,owner:traceOwner)
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            guard !replacingDrawing, currentCanvas(canvasView), toolActivation == activation else { return }
            flushPendingDrawing()
            usingTool = false
            toolActivation = nil
            store.inkHistory.setUsingTool(false,owner:traceOwner)
        }

        func flushPendingDrawing(save: Bool = false) {
            guard let canvas, !replacingDrawing, currentCanvas(canvas) else { return }
            drawingChangeSerial += 1
            commitDrawing(canvas.drawing)
            store.inkHistory.scheduleRefresh()
            if save { store.saveNow() }
        }

        func pencilInteraction(_ interaction: UIPencilInteraction,
                               didReceiveTap tap: UIPencilInteraction.Tap) {
            guard liveInput, interaction.view === canvas else { return }
            store.mode = store.mode == .eraser ? .pen : .eraser
            store.status = store.mode == .eraser ?
                "Pencil 더블탭 · 지우기" : "Pencil 더블탭 · 그리기"
        }
    }
}

private final class PencilPreviewView: UIView {
    weak var previewLayer: CAShapeLayer?

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
    }
}

private final class PencilTraceRecognizer: UIGestureRecognizer {
    enum Phase { case began, moved, ended }
    var onSample: ((CGPoint, Phase) -> Void)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first, touch.type == .pencil else { return }
        onSample?(touch.location(in: view), .began)
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first, touch.type == .pencil else { return }
        for sample in event.coalescedTouches(for: touch) ?? [touch] {
            onSample?(sample.location(in: view), .moved)
        }
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first, touch.type == .pencil else { return }
        onSample?(touch.location(in: view), .ended)
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        onSample?(touches.first?.location(in: view) ?? .zero, .ended)
        state = .cancelled
    }
}

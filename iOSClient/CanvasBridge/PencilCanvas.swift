import PencilKit
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

final class CanvasInkView: PKCanvasView {
    let inkUndoManager = UndoManager()
    override var undoManager: UndoManager? { inkUndoManager }
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
        canvas.tool = PKInkingTool(.pen, color: CanvasPalette.ink, width: 4)
        canvas.addInteraction(UIPencilInteraction(delegate: context.coordinator))
        host.addSubview(canvas)

        let overlay = PencilPreviewView(frame: host.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.backgroundColor = .clear
        overlay.isUserInteractionEnabled = false
        host.addSubview(overlay)

        let layer = context.coordinator.previewLayer
        layer.fillColor = nil
        layer.strokeColor = CanvasPalette.ink.cgColor
        layer.lineWidth = 4
        layer.lineCap = .round
        layer.lineJoin = .round
        overlay.previewLayer = layer
        overlay.layer.addSublayer(layer)

        let hoverLayer = context.coordinator.hoverLayer
        hoverLayer.fillColor = CanvasPalette.ink.withAlphaComponent(0.4).cgColor
        hoverLayer.strokeColor = CanvasPalette.ink.cgColor
        hoverLayer.lineWidth = 2
        hoverLayer.isHidden = true
        overlay.layer.addSublayer(hoverLayer)

        context.coordinator.canvas = canvas
        store.inkHistory.attach(canvas.inkUndoManager)
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
        if context.coordinator.renderedGeneration != store.inkHistory.generation ||
           context.coordinator.renderedModelDrawing != store.drawing {
            context.coordinator.replaceDrawingFromStore()
        }
        canvas.isUserInteractionEnabled = store.mode != .select
        switch store.mode {
        case .pen: canvas.tool = PKInkingTool(.pen, color: CanvasPalette.ink, width: 4)
        case .eraser: canvas.tool = store.eraserTool
        case .lasso: canvas.tool = PKLassoTool()
        case .select: break
        }
        if canvas.selection != store.inkSelection { canvas.selection = store.inkSelection }
        context.coordinator.previewLayer.isHidden = store.mode == .eraser && store.eraserPreviewWidth == nil
        context.coordinator.previewLayer.lineWidth = store.mode == .eraser ? (store.eraserPreviewWidth ?? 4) : 4
        context.coordinator.updateHover()
    }

    static func dismantleUIView(_ host: UIView, coordinator: Coordinator) {
        guard let canvas = coordinator.canvas else { return }
        canvas.delegate = nil
        if coordinator.renderedGeneration == coordinator.store.inkHistory.generation,
           canvas.drawing != coordinator.store.drawing {
            coordinator.store.updateDrawing(canvas.drawing)
            coordinator.store.saveNow()
        }
        coordinator.store.inkHistory.detach(canvas.inkUndoManager)
        coordinator.canvas = nil
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate, UIPencilInteractionDelegate,
                             UIGestureRecognizerDelegate {
        let store: CanvasStore
        weak var canvas: CanvasInkView?
        var renderedModelDrawing = PKDrawing()
        var renderedGeneration = UUID()
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

        func replaceDrawingFromStore() {
            guard let canvas else { return }
            replacingDrawing = true
            drawingChangeSerial += 1
            let manager = canvas.inkUndoManager
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
            isDrawing = false
            usingTool = false
            previewSession += 1
            previewLayer.path = nil
            replacingDrawing = false
            store.inkHistory.scheduleRefresh()
        }

        fileprivate func sample(_ point: CGPoint, phase: PencilTraceRecognizer.Phase) {
            switch phase {
            case .began:
                isDrawing = true
                hoverLayer.isHidden = true
                previewSession += 1
                previewPath = UIBezierPath()
                previewPath.move(to: point)
                previewLayer.strokeColor = store.mode == .eraser ?
                    UIColor.systemRed.withAlphaComponent(0.7).cgColor : CanvasPalette.ink.cgColor
                previewLayer.isHidden = store.mode == .eraser && store.eraserPreviewWidth == nil
                previewLayer.lineWidth = store.mode == .eraser ? (store.eraserPreviewWidth ?? 4) : 4
            case .moved:
                previewPath.addLine(to: point)
                previewLayer.path = previewPath.cgPath
            case .ended:
                isDrawing = false
                hoverPoint = point
                updateHover()
                let session = previewSession
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    guard let self, self.previewSession == session else { return }
                    self.previewLayer.path = nil
                }
            }
        }

        @objc fileprivate func hoverCanvas(_ gesture: UIHoverGestureRecognizer) {
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
            guard !isDrawing, let hoverPoint, store.mode == .pen || store.mode == .eraser,
                  store.mode != .eraser || store.eraserPreviewWidth != nil else {
                hoverLayer.isHidden = true
                return
            }
            let erasing = store.mode == .eraser
            let diameter: CGFloat = erasing ? (store.eraserPreviewWidth ?? 8) : 8
            hoverLayer.path = UIBezierPath(ovalIn:CGRect(x:-diameter / 2,y:-diameter / 2,
                                                          width:diameter,height:diameter)).cgPath
            hoverLayer.position = hoverPoint
            hoverLayer.fillColor = erasing ? UIColor.clear.cgColor :
                CanvasPalette.ink.withAlphaComponent(0.4).cgColor
            hoverLayer.strokeColor = erasing ? UIColor.systemRed.cgColor : CanvasPalette.ink.cgColor
            hoverLayer.isHidden = false
        }

        @objc fileprivate func panCanvas(_ gesture: UIPanGestureRecognizer) {
            switch gesture.state {
            case .began: panStart = store.viewport
            case .changed, .ended:
                let shift = gesture.translation(in:nil)
                store.viewport = panStart.translated(by: CGSize(width:shift.x,height:shift.y))
            default: break
            }
        }

        @objc fileprivate func pinchCanvas(_ gesture: UIPinchGestureRecognizer) {
            switch gesture.state {
            case .began:
                pinchStart = store.viewport
                pinchAnchor = gesture.location(in:gesture.view)
                pinchCenter = gesture.location(in:nil)
            case .changed, .ended:
                let center = gesture.location(in:nil)
                store.viewport = pinchStart.scaled(by:Double(gesture.scale),around:pinchAnchor,
                    centerShift:CGSize(width:center.x-pinchCenter.x,height:center.y-pinchCenter.y))
            default: break
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        func canvasViewSelectionDidChange(_ canvasView: PKCanvasView) {
            guard !replacingDrawing, renderedGeneration == store.inkHistory.generation else { return }
            store.setInkSelection(canvasView.selection)
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !replacingDrawing, renderedGeneration == store.inkHistory.generation else { return }
            drawingChangeSerial += 1
            guard !usingTool else { return }
            let serial = drawingChangeSerial
            let generation = renderedGeneration
            let drawing = canvasView.drawing
            Task { @MainActor [weak self] in
                guard let self, self.drawingChangeSerial == serial,
                      self.store.inkHistory.generation == generation else { return }
                self.renderedModelDrawing = drawing
                self.store.updateDrawing(drawing)
                self.store.inkHistory.scheduleRefresh()
            }
        }

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            guard !replacingDrawing, renderedGeneration == store.inkHistory.generation else { return }
            drawingChangeSerial += 1
            usingTool = true
            store.inkHistory.setUsingTool(true)
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            guard !replacingDrawing, renderedGeneration == store.inkHistory.generation else { return }
            flushPendingDrawing()
            usingTool = false
            store.inkHistory.setUsingTool(false)
        }

        func flushPendingDrawing(save: Bool = false) {
            guard let canvas, !replacingDrawing,
                  renderedGeneration == store.inkHistory.generation else { return }
            drawingChangeSerial += 1
            renderedModelDrawing = canvas.drawing
            store.updateDrawing(canvas.drawing)
            store.inkHistory.scheduleRefresh()
            if save { store.saveNow() }
        }

        func pencilInteraction(_ interaction: UIPencilInteraction,
                               didReceiveTap tap: UIPencilInteraction.Tap) {
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

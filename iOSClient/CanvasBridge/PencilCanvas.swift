import PencilKit
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

struct PencilCanvas: UIViewRepresentable {
    @ObservedObject var store: CanvasStore

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        host.backgroundColor = CanvasPalette.background

        let canvas = PKCanvasView(frame: host.bounds)
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
        canvas.drawing = store.drawing
        context.coordinator.renderedModelDrawing = store.drawing

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
        host.isAccessibilityElement = true
        host.accessibilityLabel = "캔버스 이동과 확대"
        host.accessibilityIdentifier = "canvasNavigationSurface"
        return host
    }

    func updateUIView(_ host: UIView, context: Context) {
        guard let canvas = context.coordinator.canvas else { return }
        host.accessibilityValue = "확대 \(Int(store.zoom * 100))%"
        if context.coordinator.renderedModelDrawing != store.drawing {
            context.coordinator.renderedModelDrawing = store.drawing
            if canvas.drawing != store.drawing { canvas.drawing = store.drawing }
        }
        canvas.isUserInteractionEnabled = store.mode != .select
        switch store.mode {
        case .pen: canvas.tool = PKInkingTool(.pen, color: CanvasPalette.ink, width: 4)
        case .eraser: canvas.tool = PKEraserTool(.vector)
        case .lasso: canvas.tool = PKLassoTool()
        case .select: break
        }
        context.coordinator.updateHover()
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate, UIPencilInteractionDelegate,
                             UIGestureRecognizerDelegate {
        let store: CanvasStore
        weak var canvas: PKCanvasView?
        var renderedModelDrawing = PKDrawing()
        let previewLayer = CAShapeLayer()
        let hoverLayer = CAShapeLayer()
        private var previewPath = UIBezierPath()
        private var previewSession = 0
        private var hoverPoint: CGPoint?
        private var isDrawing = false
        private var drawingChangeSerial = 0
        private var panStart = CanvasViewport()
        private var pinchStart = CanvasViewport()
        private var pinchAnchor = CGPoint.zero
        private var pinchCenter = CGPoint.zero

        init(store: CanvasStore) { self.store = store }

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
                previewLayer.lineWidth = store.mode == .eraser ? 20 : 4
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
            guard !isDrawing, let hoverPoint, store.mode == .pen || store.mode == .eraser else {
                hoverLayer.isHidden = true
                return
            }
            let erasing = store.mode == .eraser
            let diameter: CGFloat = erasing ? 20 : 8
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

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            drawingChangeSerial += 1
            let serial = drawingChangeSerial
            let drawing = canvasView.drawing
            Task { @MainActor [weak self] in
                guard let self, self.drawingChangeSerial == serial else { return }
                self.store.updateDrawing(drawing)
            }
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

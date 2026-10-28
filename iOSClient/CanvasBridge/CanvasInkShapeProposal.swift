import Foundation
import PencilKit
import SwiftUI

// ponytail: 한 선택 묶음의 직선·축 정렬 사각형·타원만 제안한다. 자유 도형 엔진은 별도 범위다.
struct CanvasInkShapeProposal: Identifiable {
    let id = UUID()
    let source: CanvasScene
    let selection: Set<UUID>
    let original: PKDrawing
    let node: CanvasNode

    enum Failure: String, LocalizedError {
        case selection, unsupported, invalid, ambiguous, stale
        var errorDescription: String? {
            switch self {
            case .selection: return "영역 선택 도구로 도형 하나의 원본 획을 선택하세요."
            case .unsupported: return "부분 지움이나 지원하지 않는 획입니다. 원본은 그대로 유지합니다."
            case .invalid: return "획의 좌표·필압·변환을 확인할 수 없습니다. 원본은 그대로 유지합니다."
            case .ambiguous: return "도형을 구별하기 어렵습니다. 원본을 유지하며 자동 확정하지 않습니다."
            case .stale: return "선택이나 원본이 바뀌었습니다. 최신 획을 다시 선택하세요."
            }
        }
    }

    var label: String { node.kind == .box ? "사각형" : node.kind == .ellipse ? "타원" : "직선" }

    func confirmed(in scene: CanvasScene, selection: Set<UUID>) throws -> CanvasScene {
        guard scene == source, selection == self.selection,
              !scene.nodes.contains(where: { $0.id == node.id }) else { throw Failure.stale }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard try encoder.encode(scene) == encoder.encode(source) else { throw Failure.stale }
        var next = scene
        var confirmed = node
        confirmed.confidence = .confirmed
        next.nodes.append(confirmed)
        guard next.revision < Int.max else { throw Failure.invalid }
        next.revision += 1
        guard try JSONEncoder().encode(next).count <= CanvasScene.localByteLimit else { throw Failure.invalid }
        return next
    }

    static func make(scene: CanvasScene, drawing: PKDrawing, selection: Set<UUID>) throws -> Self {
        guard !selection.isEmpty, selection.count <= 4,
              Set(drawing.strokes.map(\.id)).count == drawing.strokes.count,
              selection.isSubset(of: Set(drawing.strokes.map(\.id))) else { throw Failure.selection }
        try scene.validateNativeInkProjection()
        guard let bytes = Data(base64Encoded: scene.drawingBase64), !bytes.isEmpty,
              let stored = try? PKDrawing(data: bytes), stored == drawing, scene.strokes == CanvasScene.nativeInkStrokes(drawing) else { throw Failure.stale }
        let strokes = drawing.strokes.filter { selection.contains($0.id) }
        var paths: [[CGPoint]] = []
        for stroke in strokes {
            try validate(stroke)
            var points: [CGPoint] = []
            for p in stroke.path.interpolatedPoints(by: .distance(3)) {
                let q = p.location.applying(stroke.transform)
                guard q.x.isFinite, q.y.isFinite, abs(q.x) <= 1_000_000, abs(q.y) <= 1_000_000,
                      points.count < 4096 else { throw Failure.invalid }
                points.append(q)
            }
            guard points.count >= 2 else { throw Failure.invalid }
            paths.append(points)
        }
        let all = paths.flatMap { $0 }
        let minX = all.map(\.x).min()!, maxX = all.map(\.x).max()!
        let minY = all.map(\.y).min()!, maxY = all.map(\.y).max()!
        let w = maxX - minX, h = maxY - minY
        guard max(w,h) >= 24 else { throw Failure.ambiguous }
        var points = paths.removeFirst()
        let gap = max(3, min(w,h) * 0.18)
        while !paths.isEmpty {
            var best: (index: Int, reverse: Bool, distance: CGFloat)?
            for (i, path) in paths.enumerated() {
                for reverse in [false,true] {
                    let d = distance(points.last!, reverse ? path.last! : path.first!)
                    if best == nil || d < best!.distance { best = (i,reverse,d) }
                }
            }
            guard let best, best.distance <= gap else { throw Failure.ambiguous }
            let path = paths.remove(at: best.index)
            points.append(contentsOf: best.reverse ? Array(path.reversed()) : path)
        }
        let length = zip(points,points.dropFirst()).reduce(CGFloat(0)) { $0 + distance($1.0,$1.1) }
        let a = points.first!, b = points.last!, chord = distance(a,b)
        var candidates: [(CanvasNode.Kind,CanvasRect,Double)] = []
        if strokes.count == 1, chord >= 24, length <= chord * 1.08 {
            let error = points.map { abs((b.x-a.x)*($0.y-a.y) - (b.y-a.y)*($0.x-a.x)) / chord }.max()!
            if error <= max(1.5,chord * 0.025) {
                candidates.append((.line,.init(x:Double((a.x+b.x-chord)/2),y:Double((a.y+b.y)/2-1),
                    width:Double(chord),height:2), Double(atan2(b.y-a.y,b.x-a.x) * 180 / .pi)))
            }
        }
        if w >= 24, h >= 24, chord <= gap, length >= 2*(w+h)*0.78, length <= 2*(w+h)*1.15 {
            let edgeError = points.map { min(abs($0.x-minX),abs($0.x-maxX),abs($0.y-minY),abs($0.y-maxY)) }.max()!
            let corners = [CGPoint(x:minX,y:minY),CGPoint(x:maxX,y:minY),CGPoint(x:maxX,y:maxY),CGPoint(x:minX,y:maxY)]
            let visits = corners.allSatisfy { corner in points.contains { distance($0,corner) <= min(w,h)*0.14 } }
            if edgeError <= min(w,h)*0.075, visits {
                candidates.append((.box,.init(x:Double(minX),y:Double(minY),width:Double(w),height:Double(h)),0))
            }
        }
        if strokes.count == 1, w >= 24, h >= 24, chord <= gap, max(w/h,h/w) <= 8 {
            let normalized = points.map { CGPoint(x:($0.x-(minX+maxX)/2)/(w/2),y:($0.y-(minY+maxY)/2)/(h/2)) }
            let radial = normalized.map { abs(hypot($0.x,$0.y)-1) }.max()!
            let angles = normalized.map { atan2($0.y,$0.x) }
            let deltas = zip(angles,angles.dropFirst()).map { pair -> CGFloat in
                var delta = pair.1-pair.0
                if delta > .pi { delta -= 2 * .pi }
                if delta < -.pi { delta += 2 * .pi }
                return delta
            }
            let travel = deltas.reduce(0) { $0 + abs($1) }, turn = abs(deltas.reduce(0,+))
            if radial <= 0.10, turn >= 5.7, turn <= 6.6, travel <= 6.8 {
                candidates.append((.ellipse,.init(x:Double(minX),y:Double(minY),width:Double(w),height:Double(h)),0))
            }
        }
        guard candidates.count == 1, let candidate = candidates.first else { throw Failure.ambiguous }
        return Self(source:scene,selection:selection,original:PKDrawing(strokes:strokes),node:.init(id:UUID(),kind:candidate.0,frame:candidate.1,
            text:"",confidence:.proposal,sourceStrokeIds:strokes.map(\.id),rotationDegrees:candidate.2))
    }

    static func validate(_ stroke: PKStroke) throws {
        guard stroke.mask == nil else { throw Failure.unsupported }
        let t = stroke.transform
        guard [t.a,t.b,t.c,t.d,t.tx,t.ty].allSatisfy(\.isFinite),
              (t.a * t.d - t.b * t.c).isFinite, abs(t.a * t.d - t.b * t.c) > 0.000001,
              stroke.path.count >= 2, stroke.path.count <= 4096 else { throw Failure.invalid }
        for p in stroke.path {
            guard [p.location.x,p.location.y,p.force,p.timeOffset,p.size.width,p.size.height,
                   p.opacity,p.azimuth,p.altitude].allSatisfy({ Double($0).isFinite }),
                  p.force >= 0, p.size.width > 0, p.size.height > 0 else { throw Failure.invalid }
        }
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x-b.x,a.y-b.y) }
}

struct CanvasInkShapeOutline: Shape {
    let kind: CanvasNode.Kind
    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch kind {
        case .line: path.move(to:CGPoint(x:rect.minX,y:rect.midY)); path.addLine(to:CGPoint(x:rect.maxX,y:rect.midY))
        case .ellipse: path.addEllipse(in:rect)
        case .note: path.addRoundedRect(in:rect,cornerSize:CGSize(width:14,height:14))
        default: path.addRect(rect)
        }
        return path
    }
}

struct CanvasInkShapePreview: View {
    let proposal: CanvasInkShapeProposal
    let current: Bool
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(spacing:16) {
            Text("\(proposal.label) 보정 후보").font(.headline)
            Text("주황색은 보정 후보입니다. 원본 획을 보존하며 확인을 눌러야 요소가 추가됩니다.")
            SwiftUI.Canvas { context, size in
                let frame = proposal.node.frame
                let bounds = proposal.original.bounds.insetBy(dx:-12,dy:-12)
                let scale = min(max(1,size.width-32)/max(bounds.width,24),max(1,size.height-32)/max(bounds.height,24))
                context.translateBy(x:size.width/2,y:size.height/2)
                context.scaleBy(x:scale,y:scale)
                context.translateBy(x:-bounds.midX,y:-bounds.midY)
                #if os(macOS)
                let image = Image(nsImage:proposal.original.image(from:bounds,scale:min(1,1024/max(bounds.width,bounds.height))))
                #else
                let image = Image(uiImage:proposal.original.image(from:bounds,scale:min(1,1024/max(bounds.width,bounds.height))))
                #endif
                context.draw(image,in:bounds)
                context.translateBy(x:frame.center.x,y:frame.center.y)
                context.rotate(by:.radians(proposal.node.rotationRadians))
                let outline = CanvasInkShapeOutline(kind:proposal.node.kind).path(in:
                    CGRect(x:-frame.width/2,y:-frame.height/2,width:frame.width,height:frame.height))
                context.stroke(outline,with:.color(.orange),lineWidth:3/scale)
            }.background(Color.black).frame(minHeight:240).accessibilityLabel("원본 획과 \(proposal.label) 후보 비교")
            if !current { Text("원본이나 선택이 바뀌어 확정할 수 없습니다.").foregroundStyle(.red) }
            HStack {
                Button("취소",action:cancel).frame(minWidth:44,minHeight:44)
                Button("원본을 보존하고 확정",action:confirm).frame(minWidth:44,minHeight:44).disabled(!current)
                    .accessibilityIdentifier("canvasConfirmInkShape")
            }
        }.padding().accessibilityIdentifier("canvasInkShapePreview")
    }
}

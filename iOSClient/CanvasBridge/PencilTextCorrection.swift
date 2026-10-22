import Foundation
import CoreGraphics

enum CanvasPencilTextGesture {
    case erase, join, split
}

struct CanvasPencilTextChange {
    let range: NSRange
    let replacement: String
}

struct CanvasPencilTextSnapshot {
    let id = UUID()
    let text: String
    let session: UUID
    let selection: NSRange

    func matches(text: String, session: UUID?, selection: NSRange) -> Bool {
        self.session == session && self.selection == selection && self.text.utf8.elementsEqual(text.utf8)
    }
}

enum CanvasPencilTextCorrection {
    static func replacement(in text: String, selection: NSRange, with replacement: String) -> CanvasPencilTextChange? {
        guard let whole = canvasSelectedCharacterRange(in:text,selection:selection), whole == selection,
              let range = Range(whole,in:text), !replacement.isEmpty,
              !text[range].utf8.elementsEqual(replacement.utf8) else { return nil }
        return CanvasPencilTextChange(range:whole,replacement:replacement)
    }

    // ponytail: 화면 좌표의 단일 획 휴리스틱이다. 실기기 표본으로 아래 임계치를 교정한다.
    static func gesture(for points: [CGPoint], minimumEraseWidth: CGFloat = 24) -> CanvasPencilTextGesture? {
        guard minimumEraseWidth.isFinite, minimumEraseWidth >= 1, minimumEraseWidth <= 24,
              (4...4096).contains(points.count),
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              let first = points.first, let last = points.last else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        var travelX: CGFloat = 0, travelY: CGFloat = 0, length: CGFloat = 0
        for (a, b) in zip(points, points.dropFirst()) {
            minX = min(minX, b.x); maxX = max(maxX, b.x)
            minY = min(minY, b.y); maxY = max(maxY, b.y)
            let dx = b.x - a.x, dy = b.y - a.y
            travelX += abs(dx); travelY += abs(dy)
            length += hypot(dx, dy)
        }
        let width = maxX - minX, height = maxY - minY, dy = last.y - first.y
        guard width.isFinite, height.isFinite, length.isFinite,
              travelX.isFinite, travelY.isFinite else { return nil }

        if height >= 28, width <= min(12, height * 0.18),
           abs(dy) >= height * 0.9, travelY <= abs(dy) * 1.15,
           length <= abs(dy) * 1.25 {
            return dy < 0 ? .join : .split
        }

        // 원래 화면 좌표의 join/split 판정 뒤, 삭제 획만 주축에 맞춘다.
        // 공분산은 정규화 좌표로 구해 유한한 큰 좌표의 제곱 overflow를 피한다.
        let scale = max(width, height)
        guard scale > 0 else { return nil }
        let normalized = points.map { CGPoint(x:($0.x-minX)/scale,y:($0.y-minY)/scale) }
        let meanX = normalized.reduce(CGFloat.zero) { $0+$1.x } / CGFloat(points.count)
        let meanY = normalized.reduce(CGFloat.zero) { $0+$1.y } / CGFloat(points.count)
        var xx: CGFloat = 0, xy: CGFloat = 0, yy: CGFloat = 0
        for point in normalized {
            let x = point.x-meanX, y = point.y-meanY
            xx += x*x; xy += x*y; yy += y*y
        }
        let angle = atan2(2*xy,xx-yy)/2, cosine = cos(angle), sine = sin(angle)
        let erasePoints = normalized.map { point in
            let x = point.x-meanX, y = point.y-meanY
            return CGPoint(x:(x*cosine+y*sine)*scale,y:(-x*sine+y*cosine)*scale)
        }
        guard erasePoints.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let eraseWidth = erasePoints.map(\.x).max()! - erasePoints.map(\.x).min()!
        let eraseHeight = erasePoints.map(\.y).max()! - erasePoints.map(\.y).min()!
        var eraseTravelX: CGFloat = 0, eraseTravelY: CGFloat = 0
        for (a, b) in zip(erasePoints,erasePoints.dropFirst()) {
            eraseTravelX += abs(b.x-a.x); eraseTravelY += abs(b.y-a.y)
        }
        // iPad44 실제 4개 획의 투영 height/width 최댓값은 약 0.655다.
        guard eraseWidth.isFinite, eraseHeight.isFinite, eraseTravelX.isFinite, eraseTravelY.isFinite,
              eraseWidth >= minimumEraseWidth, eraseHeight <= eraseWidth * 0.7,
              eraseTravelX >= eraseWidth * 3, eraseTravelY <= eraseTravelX * 0.5 else { return nil }
        let excursion = max(min(8, minimumEraseWidth / 3), eraseWidth * 0.45)
        var extreme = erasePoints[0].x
        var direction = 0, reversals = 0
        for point in erasePoints.dropFirst() {
            if direction == 0 {
                if abs(point.x - extreme) >= excursion {
                    direction = point.x > extreme ? 1 : -1
                    extreme = point.x
                }
            } else if direction > 0 {
                if point.x > extreme { extreme = point.x }
                else if extreme - point.x >= excursion {
                    reversals += 1; direction = -1; extreme = point.x
                }
            } else {
                if point.x < extreme { extreme = point.x }
                else if point.x - extreme >= excursion {
                    reversals += 1; direction = 1; extreme = point.x
                }
            }
        }
        return reversals >= 3 ? .erase : nil
    }

    /// range는 UTF-16 단위다. join/split은 UITextView가 제공한 길이 0의 caret을 받는다.
    static func edit(in text: String, gesture: CanvasPencilTextGesture,
                     range: NSRange) -> CanvasPencilTextChange? {
        if gesture == .erase {
            guard let whole = canvasSelectedCharacterRange(in: text, selection: range) else { return nil }
            return CanvasPencilTextChange(range: whole, replacement: "")
        }
        guard range.length == 0, range.location >= 0, range.location <= text.utf16.count,
              let caret = characterBoundary(in: text, offset: range.location) else { return nil }
        switch gesture {
        case .erase: return nil
        case .join:
            var lower = caret, upper = caret
            while lower > text.startIndex {
                let previous = text.index(before: lower)
                guard text[previous] == " " else { break }
                lower = previous
            }
            while upper < text.endIndex, text[upper] == " " {
                upper = text.index(after: upper)
            }
            guard lower < upper, lower > text.startIndex, upper < text.endIndex,
                  !text[text.index(before:lower)].isWhitespace, !text[upper].isWhitespace else { return nil }
            return CanvasPencilTextChange(range: NSRange(lower..<upper, in: text), replacement: "")
        case .split:
            guard caret > text.startIndex, caret < text.endIndex,
                  !text[text.index(before: caret)].isWhitespace, !text[caret].isWhitespace else { return nil }
            return CanvasPencilTextChange(range: range, replacement: " ")
        }
    }

    private static func characterBoundary(in text: String, offset: Int) -> String.Index? {
        var units = 0
        for index in text.indices {
            if units == offset { return index }
            units += String(text[index]).utf16.count
            if units > offset { return nil }
        }
        return units == offset ? text.endIndex : nil
    }
}

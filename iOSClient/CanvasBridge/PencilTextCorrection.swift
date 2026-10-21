import Foundation
import CoreGraphics

enum CanvasPencilTextGesture {
    case erase, join, split
}

struct CanvasPencilTextChange {
    let range: NSRange
    let replacement: String
}

enum CanvasPencilTextCorrection {
    // ponytail: 화면 좌표의 단일 획 휴리스틱이다. 실기기 표본으로 아래 임계치를 교정한다.
    static func gesture(for points: [CGPoint]) -> CanvasPencilTextGesture? {
        guard (4...4096).contains(points.count),
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

        guard width >= 24, height <= width * 0.55,
              travelX >= width * 3, travelY <= travelX * 0.5 else { return nil }
        let excursion = max(8, width * 0.45)
        var extreme = first.x
        var direction = 0, reversals = 0
        for point in points.dropFirst() {
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
                guard text[previous].unicodeScalars.allSatisfy({ $0.properties.isWhitespace }) else { break }
                lower = previous
            }
            while upper < text.endIndex,
                  text[upper].unicodeScalars.allSatisfy({ $0.properties.isWhitespace }) {
                upper = text.index(after: upper)
            }
            guard lower < upper, lower > text.startIndex, upper < text.endIndex else { return nil }
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

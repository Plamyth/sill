import Foundation
import PencilKit
import SwiftUI

struct CanvasInkMathProposal: Identifiable {
    let id = UUID()
    let source: CanvasScene
    let selection: Set<UUID>
    let original: PKDrawing
    let recognizedText: String?
    let nodeID = UUID()

    enum Failure: String, LocalizedError {
        case selection, stale, syntax, divisionByZero, overflow, precision, limit, unreadable
        var errorDescription: String? {
            switch self {
            case .selection: return "영역 선택 도구로 계산할 원본 수식을 선택하세요."
            case .stale: return "원본이나 선택이 바뀌었습니다. 최신 수식을 다시 선택하세요."
            case .syntax: return "숫자·소수점·괄호와 기본 사칙연산만 지원합니다. 변수나 모호한 숫자는 계산하지 않습니다."
            case .divisionByZero: return "0으로 나눌 수 없습니다. 원본 수식은 유지합니다."
            case .overflow: return "계산 가능한 숫자 범위를 벗어났습니다. 원본 수식은 유지합니다."
            case .precision: return "정확한 유한소수로 계산할 수 없습니다. 근삿값을 자동 확정하지 않습니다."
            case .limit: return "식의 길이·숫자 자릿수·괄호 깊이가 지원 범위를 넘었습니다."
            case .unreadable: return "원본 획과 저장 자료를 확인할 수 없습니다. 원본을 보존합니다."
            }
        }
    }

    static func capture(scene: CanvasScene, drawing: PKDrawing, selection: Set<UUID>, recognized: String?) throws -> Self {
        guard !selection.isEmpty, selection.isSubset(of:Set(drawing.strokes.map(\.id))),
              Set(drawing.strokes.map(\.id)).count == drawing.strokes.count else { throw Failure.selection }
        try scene.validateNativeInkProjection()
        guard let bytes = Data(base64Encoded:scene.drawingBase64), !bytes.isEmpty,
              let native = try? PKDrawing(data:bytes), native == drawing,
              CanvasScene.nativeInkStrokes(native) == scene.strokes,
              scene.strokes.allSatisfy({ $0.points.allSatisfy { [$0.x,$0.y,$0.pressure].allSatisfy(\.isFinite) } }),
              recognized.map({ $0.utf8.count <= 1024 }) ?? true else { throw Failure.unreadable }
        let original = PKDrawing(strokes:native.strokes.filter { selection.contains($0.id) })
        let bounds = original.bounds
        guard !bounds.isNull, !bounds.isEmpty,
              [bounds.minX,bounds.minY,bounds.maxX,bounds.maxY,bounds.width,bounds.height].allSatisfy(\.isFinite),
              bounds.width <= 1_000_000, bounds.height <= 1_000_000 else { throw Failure.unreadable }
        return .init(source:scene,selection:selection,original:original,recognizedText:recognized)
    }

    func confirmed(in scene: CanvasScene, selection: Set<UUID>, expression: String) throws -> CanvasScene {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard scene == source, self.selection == selection,
              try encoder.encode(scene) == encoder.encode(source),
              !scene.nodes.contains(where:{ $0.id == nodeID }) else { throw Failure.stale }
        let calculation = try Self.calculate(expression)
        let text = "인식 후보: \(recognizedText ?? "없음 · 직접 교정")\n수정한 식: \(expression)\n계산: \(calculation.expression) = \(calculation.result)"
        let bounds = original.bounds
        var next = scene
        next.nodes.append(.init(id:nodeID,kind:.note,
            frame:.init(x:Double(bounds.minX),y:Double(bounds.maxY+16),width:360,height:180),
            text:text,confidence:.confirmed,sourceStrokeIds:original.strokes.map(\.id)))
        guard next.revision < Int.max else { throw Failure.overflow }
        next.revision += 1
        guard try encoder.encode(next).count <= CanvasScene.localByteLimit else { throw Failure.limit }
        return next
    }

    static func calculate(_ expression: String) throws -> (expression: String,result: String) {
        guard expression.utf8.count <= 256 else { throw Failure.limit }
        var text = expression.trimmingCharacters(in:.whitespacesAndNewlines)
            .replacingOccurrences(of:"×",with:"*").replacingOccurrences(of:"÷",with:"/")
            .replacingOccurrences(of:"−",with:"-")
        if text.last == "=" { text.removeLast() }
        var parser = Arithmetic(text:text)
        let value = try parser.expression(depth:0)
        parser.spaces()
        guard parser.index == parser.input.count else { throw Failure.syntax }
        return (text,NSDecimalNumber(decimal:value).stringValue)
    }

    // ponytail: Decimal과 재귀 하강만 사용한다. 변수·함수·근삿값·동적 실행은 지원하지 않는다.
    private struct Arithmetic {
        let input: [Character]
        var index = 0
        init(text: String) { input = Array(text) }
        mutating func spaces() { while index < input.count && input[index].isWhitespace { index += 1 } }
        mutating func take(_ c: Character) -> Bool {
            spaces()
            if index < input.count && input[index] == c { index += 1; return true }
            return false
        }
        mutating func expression(depth: Int) throws -> Decimal {
            var value = try term(depth:depth)
            while true {
                if take("+") { value = try operation(value,try term(depth:depth),"+") }
                else if take("-") { value = try operation(value,try term(depth:depth),"-") }
                else { return value }
            }
        }
        mutating func term(depth: Int) throws -> Decimal {
            var value = try primary(depth:depth)
            while true {
                if take("*") { value = try operation(value,try primary(depth:depth),"*") }
                else if take("/") { value = try operation(value,try primary(depth:depth),"/") }
                else { return value }
            }
        }
        mutating func primary(depth: Int) throws -> Decimal {
            guard depth < 16 else { throw Failure.limit }
            if take("+") { return try primary(depth:depth+1) }
            if take("-") { return try operation(0,try primary(depth:depth+1),"-") }
            if take("(") {
                let value = try expression(depth:depth+1)
                guard take(")") else { throw Failure.syntax }
                return value
            }
            spaces()
            let start = index
            var digits = 0, dot = false
            while index < input.count {
                let c = input[index]
                if c >= "0" && c <= "9" { digits += 1 }
                else if c == "." && !dot { dot = true }
                else { break }
                index += 1
            }
            guard digits > 0 else { throw Failure.syntax }
            guard digits <= 28 else { throw Failure.limit }
            guard let number = Decimal(string:String(input[start..<index]),locale:Locale(identifier:"en_US_POSIX")),
                  !number.isNaN else { throw Failure.overflow }
            return number
        }
        func operation(_ lhs: Decimal, _ rhs: Decimal, _ symbol: Character) throws -> Decimal {
            var a = lhs, b = rhs, result = Decimal()
            let error: Decimal.CalculationError
            switch symbol {
            case "+": error = NSDecimalAdd(&result,&a,&b,.plain)
            case "-": error = NSDecimalSubtract(&result,&a,&b,.plain)
            case "*": error = NSDecimalMultiply(&result,&a,&b,.plain)
            default:
                guard b != 0 else { throw Failure.divisionByZero }
                func coefficient(_ value: Decimal) throws -> UInt64 {
                    let text = NSDecimalNumber(decimal:value).stringValue
                    guard text.allSatisfy({ ($0 >= "0" && $0 <= "9") || $0 == "." || $0 == "-" }) else { throw Failure.limit }
                    let digits = text.filter { $0 >= "0" && $0 <= "9" }.drop(while:{ $0 == "0" })
                    guard digits.count <= 18, let value = UInt64(digits.isEmpty ? "0" : String(digits)) else { throw Failure.limit }
                    return value
                }
                var numerator = try coefficient(a), denominator = try coefficient(b)
                let originalDenominator = denominator
                while denominator != 0 { let remainder = numerator % denominator; numerator = denominator; denominator = remainder }
                denominator = originalDenominator / max(1,numerator)
                while denominator % 2 == 0 { denominator /= 2 }
                while denominator % 5 == 0 { denominator /= 5 }
                guard denominator == 1 else { throw Failure.precision }
                error = NSDecimalDivide(&result,&a,&b,.plain)
            }
            if error == .lossOfPrecision { throw Failure.precision }
            guard error == .noError, !result.isNaN else { throw Failure.overflow }
            return result
        }
    }
}

struct CanvasInkMathOriginalPreview: View {
    let drawing: PKDrawing
    var body: some View {
        let bounds = drawing.bounds.insetBy(dx:-12,dy:-12)
        let scale = min(1,1024/max(1,max(bounds.width,bounds.height)))
        #if os(macOS)
        Image(nsImage:drawing.image(from:bounds,scale:scale)).resizable().scaledToFit()
            .background(Color.black).accessibilityLabel("선택한 수식 원본 획")
        #else
        Image(uiImage:drawing.image(from:bounds,scale:scale)).resizable().scaledToFit()
            .background(Color.black).accessibilityLabel("선택한 수식 원본 획")
        #endif
    }
}

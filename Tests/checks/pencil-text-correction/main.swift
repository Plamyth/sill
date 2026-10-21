import Foundation
import CoreGraphics

var checks = 0
var failures = 0
func check(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition { failures += 1; print("실패: \(message)") }
}

func changed(_ text: String, _ gesture: CanvasPencilTextGesture, _ range: NSRange) -> String? {
    guard let change = CanvasPencilTextCorrection.edit(in: text, gesture: gesture, range: range) else { return nil }
    return (text as NSString).replacingCharacters(in: change.range, with: change.replacement)
}

let clusters = ["👩🏽‍💻", "👍🏽", "🇰🇷", "한", "e\u{301}", "\r\n", "क्‍ष", "A"]
for cluster in clusters {
    let text = "앞" + cluster + "뒤"
    for offset in 0..<cluster.utf16.count {
        let range = NSRange(location: 1 + offset, length: 1)
        let edit = CanvasPencilTextCorrection.edit(in: text, gesture: .erase, range: range)
        check(edit?.range == NSRange(location: 1, length: cluster.utf16.count), "전체 글자 삭제 범위 \(cluster)/\(offset)")
        check(changed(text, .erase, range) == "앞뒤", "주변 글자 보존 \(cluster)/\(offset)")
        if offset > 0 {
            let caret = NSRange(location: 1 + offset, length: 0)
            check(changed(text, .split, caret) == nil, "글자 내부 나누기 거부 \(cluster)/\(offset)")
            check(changed(text, .join, caret) == nil, "글자 내부 합치기 거부 \(cluster)/\(offset)")
        }
    }
    let whitespace = cluster.allSatisfy(\.isWhitespace)
    check(changed(text, .split, NSRange(location: 1, length: 0)) == (whitespace ? nil : "앞 " + cluster + "뒤"), "글자 앞 경계 나누기 \(cluster)")
    check(changed(text, .split, NSRange(location: 1 + cluster.utf16.count, length: 0)) == (whitespace ? nil : "앞" + cluster + " 뒤"), "글자 뒤 경계 나누기 \(cluster)")
}
check(changed("a👩🏽‍💻e\u{301}z", .erase, NSRange(location: 2, length: 8)) == "az", "양끝 부분 글자 삭제 확대")

for space in [" ", "   ", "\t", "\n", "\r\n", " \t\n ", "\u{a0}", "\u{2003}", "\u{2028}", "\u{3000}"] {
    let text = "가" + space + "다"
    var caret = 1
    for character in space {
        check(changed(text, .join, NSRange(location: caret, length: 0)) == "가다", "구분자 앞에서 합치기 \(space.debugDescription)")
        check(changed(text, .split, NSRange(location: caret, length: 0)) == nil, "이미 있는 공백 앞 나누기 거부")
        caret += String(character).utf16.count
    }
    check(changed(text, .join, NSRange(location: caret, length: 0)) == "가다", "구분자 뒤에서 합치기")
    check(changed(text, .split, NSRange(location: caret, length: 0)) == nil, "이미 있는 공백 뒤 나누기 거부")
}
check(changed("가다", .split, NSRange(location: 1, length: 0)) == "가 다", "한글 나누기")
check(changed("a b c", .join, NSRange(location: 2, length: 0)) == "ab c", "인접 공백만 합치기")
for decoratedSpace in [" \u{301}", "\u{a0}\u{301}", " \u{fe0f}"] {
    let text = "가" + decoratedSpace + "다"
    for caret in [1, 1 + decoratedSpace.utf16.count] {
        check(changed(text, .join, NSRange(location: caret, length: 0)) == nil, "공백에 붙은 비공백 스칼라 보존")
    }
}
for gesture in [CanvasPencilTextGesture.join, .split] {
    check(changed("가\r\n다", gesture, NSRange(location: 2, length: 0)) == nil, "CRLF 내부 caret 거부")
    check(changed("가 다", gesture, NSRange(location: -1, length: 0)) == nil, "음수 caret 거부")
}
for text in ["가다", "a-b", "a\u{200b}b", "가", "", " 가", "가 ", " \n "] {
    for offset in 0...text.utf16.count {
        check(changed(text, .join, NSRange(location: offset, length: 0)) == nil, "합칠 내부 공백이 없으면 거부 \(text.debugDescription)")
    }
}
for text in ["", "가", "가다", "👩🏽‍💻"] {
    for offset in [0, text.utf16.count] {
        check(changed(text, .split, NSRange(location: offset, length: 0)) == nil, "양끝 나누기 거부")
    }
}
let invalid = [NSRange(location: -1, length: 1), NSRange(location: 0, length: -1),
               NSRange(location: NSNotFound, length: 1), NSRange(location: Int.max, length: Int.max),
               NSRange(location: 1, length: Int.max), NSRange(location: 4, length: 0)]
for gesture in [CanvasPencilTextGesture.erase, .join, .split] {
    for range in invalid {
        check(changed("가 다", gesture, range) == nil, "잘못된 범위 거부 \(gesture)/\(range)")
    }
}
for gesture in [CanvasPencilTextGesture.join, .split] {
    check(changed("가 다", gesture, NSRange(location: 1, length: 1)) == nil, "caret 외 선택 거부")
}
check(changed("가다", .erase, NSRange(location: 1, length: 0)) == nil, "삭제할 선택 없음")

func stroke(_ pairs: [(CGFloat, CGFloat)]) -> [CGPoint] { pairs.map { CGPoint(x: $0.0, y: $0.1) } }
let down = stroke([(10, 0), (11, 10), (9, 20), (10, 40)])
let scratch = stroke([(0, 0), (30, 2), (0, 4), (30, 6), (0, 8)])
check(CanvasPencilTextCorrection.gesture(for: down) == .split, "위에서 아래 나누기")
check(CanvasPencilTextCorrection.gesture(for: Array(down.reversed())) == .join, "아래에서 위 합치기")
check(CanvasPencilTextCorrection.gesture(for: scratch) == .erase, "충분한 좌우 반전 삭제")
check(CanvasPencilTextCorrection.gesture(for: Array(scratch.reversed())) == .erase, "반대 방향 삭제")
check(CanvasPencilTextCorrection.gesture(for: scratch.map { CGPoint(x: $0.x + 200, y: $0.y - 90) }) == .erase, "좌표 이동 불변")
let rejected: [[CGPoint]] = [
    [], [CGPoint.zero], Array(down.prefix(3)), Array(repeating: .zero, count: 10),
    stroke([(0, 0), (1, 3), (-1, 6), (0, 9)]),
    stroke([(0, 0), (10, 10), (20, 20), (30, 30)]),
    stroke([(0, 0), (0, 40), (0, 0), (0, 40)]),
    stroke([(0, 0), (0, 40), (0, 20), (0, 0)]),
    stroke([(0, 0), (10, 0), (20, 0), (40, 0)]),
    stroke([(0, 0), (30, 2), (0, 4), (30, 6)]),
    stroke([(0, 0), (4, 1), (0, 2), (4, 3), (0, 4), (4, 5)]),
    stroke([(0, 0), (30, 30), (0, 60), (30, 90), (0, 120)]),
    stroke([(0, 0), (12, 0), (12, 12), (0, 12), (0, 0)]),
    stroke([(0, 0), (0, 28), (8, 28), (8, 28)]),
    stroke([(0, 0), (0, 9), (0, 18), (0, 27.9)]),
    stroke([(0, 0), (0, 10), (.nan, 20), (0, 40)]),
    stroke([(0, 0), (0, 10), (0, .infinity), (0, 40)]),
    stroke([(0, 0), (0, 10), (-.infinity, 20), (0, 40)]),
    stroke([(-CGFloat.greatestFiniteMagnitude, 0), (CGFloat.greatestFiniteMagnitude, 0), (0, 0), (1, 0)]),
    Array(repeating: .zero, count: 4097)
]
for (index, points) in rejected.enumerated() {
    check(CanvasPencilTextCorrection.gesture(for: points) == nil, "애매하거나 잘못된 획 거부 \(index)")
}
let minimum = stroke([(0, 0), (0, 9), (0, 18), (0, 28)])
check(CanvasPencilTextCorrection.gesture(for: minimum) == .split, "최소 세로 길이 경계")
check(CanvasPencilTextCorrection.gesture(for: (0..<4096).map { CGPoint(x: 0, y: CGFloat($0) / 100) }) == .split, "표본 상한 안의 직선")
let noisy = (0..<101).map { CGPoint(x: CGFloat($0 % 2) * 0.1, y: CGFloat($0) * 0.4) }
check(CanvasPencilTextCorrection.gesture(for: noisy) == .split, "미세 가로 잡음 허용")
let falseScratch = stroke([(0, 0), (40, 0), (39, 0), (40, 0), (39, 0), (40, 0), (39, 0), (0, 0)])
check(CanvasPencilTextCorrection.gesture(for: falseScratch) == nil, "미세 반전을 scratch로 세지 않음")
let narrowScratch = stroke([(0,0),(8,1),(0,0),(8,1),(0,0),(8,1)])
check(CanvasPencilTextCorrection.gesture(for:narrowScratch,minimumEraseWidth:8) == .erase,"폭8pt 글자 기준의 scratch")
check(CanvasPencilTextCorrection.gesture(for:narrowScratch) == nil,"명시한 글자 폭 없이 작은 획을 확대 해석하지 않음")
for invalid in [CGFloat.nan, -CGFloat.infinity, CGFloat(0), CGFloat(25)] {
    check(CanvasPencilTextCorrection.gesture(for:scratch,minimumEraseWidth:invalid) == nil,"잘못된 글자 폭 거부")
}
print("검사 \(checks)개, 실패 \(failures)개")
if failures > 0 { exit(1) }

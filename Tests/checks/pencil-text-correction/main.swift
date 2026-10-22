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

for space in [" ", "   "] {
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
for separator in ["\t", "\n", "\r\n", " \t\n ", "\n\n", "  \n", "\u{a0}", "\u{2003}", "\u{2028}", "\u{2029}", "\u{3000}"] {
    let text = "가" + separator + "다"
    for offset in 1...(1 + separator.utf16.count) {
        check(changed(text,.join,NSRange(location:offset,length:0)) == nil,
              "줄·문단·탭·의미 있는 Unicode 공백 보존 \(separator.debugDescription)/\(offset)")
    }
}
for text in ["앞 \n뒤", "앞\n 뒤", "앞  \r\n뒤", "앞\t 뒤", "앞 \u{a0}뒤", "앞\n\n 뒤"] {
    for offset in 0...text.utf16.count {
        check(changed(text,.join,NSRange(location:offset,length:0)) == nil,"Markdown 경계 합치기 거부 \(text.debugDescription)/\(offset)")
    }
}
check(changed("앞 뒤\n\n다 라",.join,NSRange(location:1,length:0)) == "앞뒤\n\n다 라","선택한 같은 줄의 공백만 합치고 다른 문단 보존")
for cluster in clusters {
    let text = "앞" + cluster + "뒤"
    let selection = NSRange(location:1,length:cluster.utf16.count)
    let edit = CanvasPencilTextCorrection.replacement(in:text,selection:selection,with:"교정")
    check(edit?.range == selection && edit?.replacement == "교정","선택한 전체 Character의 명시 교정 \(cluster)")
    if let edit {
        check((text as NSString).replacingCharacters(in:edit.range,with:edit.replacement) == "앞교정뒤","교정의 인접 글자 보존 \(cluster)")
    }
    for offset in 1..<cluster.utf16.count {
        check(CanvasPencilTextCorrection.replacement(in:text,selection:NSRange(location:1+offset,length:1),with:"교정") == nil,
              "부분 Character 교정 거부 \(cluster)/\(offset)")
    }
    check(CanvasPencilTextCorrection.replacement(in:text,selection:selection,with:cluster) == nil,"동일 UTF8 교정은 변경 없음")
    check(CanvasPencilTextCorrection.replacement(in:text,selection:selection,with:"") == nil,"빈 교정은 선택 삭제로 우회하지 않음")
}
let snapshotSession = UUID()
let snapshotSelection = NSRange(location:1,length:2)
let snapshotText = "앞e\u{301}뒤"
let snapshot = CanvasPencilTextSnapshot(text:snapshotText,session:snapshotSession,selection:snapshotSelection)
check(snapshot.matches(text:snapshotText,session:snapshotSession,selection:snapshotSelection),"정확한 원문·session·selection snapshot")
check(!snapshot.matches(text:"앞é뒤",session:snapshotSession,selection:snapshotSelection),"정규화 동등 문자열도 UTF8가 다르면 stale")
check(!snapshot.matches(text:snapshotText,session:UUID(),selection:snapshotSelection),"새 편집 세션은 stale")
check(!snapshot.matches(text:snapshotText,session:nil,selection:snapshotSelection),"퇴역 편집 세션은 stale")
check(!snapshot.matches(text:snapshotText,session:snapshotSession,selection:NSRange(location:0,length:1)),"달라진 선택은 stale")
let normalizationEdit = CanvasPencilTextCorrection.replacement(in:snapshotText,selection:snapshotSelection,with:"é")
check(normalizationEdit?.replacement.utf8.elementsEqual("é".utf8) == true,"사용자가 명시한 Unicode 정규화 교정만 허용")
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
for range in invalid + [NSRange(location:1,length:0)] {
    check(CanvasPencilTextCorrection.replacement(in:"가 다",selection:range,with:"교정") == nil,"잘못된 범위·빈 선택의 수동 교정 거부")
}
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
// iPad44 실제 Pencil 표본. 원본 JSON SHA-256 a5ab91e6ae1e0a0ce154cc582793b28b1ad256c30b3098e23fccb4059aec4c1e
let device44Scratches: [[CGPoint]] = [
    stroke([ // 원본 event 1, 175점
        (35,41.5),(35,41.5),(34.5,41.5),(34.5,41.5),(34,41.5),(34,41.5),(33.5,41.5),(33,41.5),
        (32.5,41.5),(32,41.5),(31,42.5),(30,43.5),(28.5,44.5),(27,46),(25,47.5),(23,49.5),
        (21,51.5),(18.5,54),(17,55.5),(15.5,57),(14.5,58.5),(14,59),(13.5,59.5),(13.5,60),
        (13.5,60),(14,60),(15,59.5),(16,59),(17,58.5),(18.5,57.5),(20,56.5),(22,55),
        (23.5,54),(25.5,53),(27.5,51.5),(29,50.5),(30.5,49.5),(32,48.5),(33.5,47.5),(34.5,46.5),
        (35,45.5),(36,44.5),(36.5,44.5),(36.5,44),(36.5,44),(36,44),(35,44.5),(33.5,45.5),
        (32,46.5),(30.5,48),(28.5,49.5),(26,51),(24,52.5),(21.5,54.5),(19.5,56),(17.5,57),
        (16,58.5),(14.5,59.5),(13.5,61),(12.5,62),(12,62.5),(12,63),(12,63),(12.5,63),
        (13,63),(14,63),(15,62.5),(16,61.5),(17.5,60.5),(19.5,59),(21,57.5),(23,56),
        (25,54.5),(26.5,53.5),(28.5,52),(30,51),(31.5,49.5),(32.5,48),(33.5,47.5),(34,46.5),
        (34,46.5),(34,46.5),(33.5,46.5),(32.5,47),(31,48),(29,49.5),(27,51),(25,53),
        (22.5,55),(20.5,57),(18.5,59),(17,61),(16,62.5),(15,64.5),(14,66),(14,67),
        (14,67.5),(14.5,68),(15.5,68),(17,68),(19,68),(21,68),(23.5,67),(26,66),
        (28,65),(30.5,63.5),(32.5,62),(34.5,60.5),(36,59),(37,57.5),(38.5,56.5),(39.5,55),
        (41,53.5),(41.5,53),(42,52),(42.5,52),(42.5,52),(42.5,52),(42,52),(41,52),
        (40,53),(38.5,53.5),(37,55),(35.5,56.5),(33.5,58),(32,59.5),(30.5,60.5),(29,62),
        (27.5,63.5),(26.5,64.5),(25,66),(24,66.5),(23.5,67),(23.5,67.5),(23.5,67.5),(23.5,67.5),
        (24.5,67.5),(26,66.5),(27.5,65.5),(29,64.5),(31,63),(33,61.5),(34.5,60),(36,58.5),
        (37,57.5),(38.5,56.5),(39.5,55.5),(41,55),(41.5,54.5),(42,54.5),(42,54.5),(42,55),
        (41.5,56),(40.5,57.5),(39.5,59),(38,60.5),(36.5,62),(35,63.5),(34,65),(32.5,67),
        (31,68),(30,69),(29,69.5),(28.5,70.5),(28,70.5),(27.5,71),(27.5,71),(28,71),
        (28.5,70.5),(29,70),(30.5,69.5),(31.5,68.5),(33,67.5),(34,67),(40,58.5),
    ]),
    stroke([ // 원본 event 3, 118점
        (35,44),(34.5,44),(34,44),(34,44),(33.5,44),(33,44),(32.5,44),(32.5,44),
        (32,44.5),(31.5,44.5),(31,45),(30,46),(29.5,47),(28.5,48),(27,49.5),(25.5,51.5),
        (24,53.5),(22,55.5),(20.5,57),(19.5,59),(18.5,60),(18,61),(17.5,62),(17.5,62.5),
        (17.5,62.5),(17.5,62.5),(18.5,62.5),(19.5,61.5),(20.5,60.5),(22,59.5),(23.5,58),(25,56.5),
        (26.5,55),(28.5,53.5),(29.5,52),(31.5,50),(32.5,49),(34,47.5),(35,46),(36,44.5),
        (36.5,43.5),(37.5,42),(37.5,41.5),(37.5,41.5),(37.5,41.5),(37,42),(36,43.5),(34.5,45),
        (33.5,47),(31.5,49),(29.5,51.5),(27.5,54),(25.5,56.5),(23.5,59),(22,61),(20,63),
        (19,64.5),(18,65.5),(17.5,67),(17.5,67),(18,67.5),(19,67.5),(20.5,67),(22.5,66.5),
        (25,65.5),(27,64),(29,63),(31,61),(33,59.5),(34.5,58),(36,56),(37.5,54.5),
        (38.5,53.5),(39.5,52),(40.5,51),(41.5,50.5),(42,50),(42,49.5),(42,49.5),(41.5,50),
        (41,51),(39.5,52),(38,53),(36.5,54.5),(35,56.5),(34,58),(32.5,59.5),(31,61.5),
        (30,63),(29,64),(28.5,65),(28,66),(27.5,66),(27.5,66.5),(28,66.5),(29,66.5),
        (30,65.5),(31.5,64.5),(33,63),(34.5,61.5),(36,60),(37.5,58.5),(39,57.5),(40.5,56.5),
        (42,55.5),(42.5,54.5),(43.5,54),(43.5,54),(43.5,54),(43.5,55),(42.5,56),(41.5,57.5),
        (40,59),(39,60.5),(37.5,62),(36.5,64),(36,65.5),(35.5,69.5),
    ]),
    stroke([ // 원본 event 5, 94점
        (38,85.5),(37.5,85.5),(37,85.5),(36.5,85.5),(36,85.5),(35.5,85.5),(35,86),(34,86.5),
        (33,87.5),(32,89),(30.5,91),(29,93),(27,95.5),(25.5,97.5),(24,99.5),(23,101.5),
        (22,103),(21.5,104),(21.5,104.5),(21.5,104.5),(22.5,104.5),(24,104),(25.5,102.5),(27.5,101.5),
        (29.5,99.5),(31,98),(32.5,96),(34,94.5),(35.5,92.5),(37,90.5),(38.5,88.5),(40,86.5),
        (41,85),(42.5,83),(43,81.5),(43.5,80.5),(44,80),(44,80),(44,80),(43,80.5),
        (42,81.5),(40.5,82.5),(39,84),(37.5,85.5),(36,87),(35,89),(34,90),(32.5,91.5),
        (31.5,93),(30.5,94.5),(30,95.5),(29.5,96.5),(29,97),(29,97.5),(29,97.5),(29,98),
        (29.5,98),(30,97.5),(31,97.5),(32,96.5),(33,96),(34,95),(35,94),(36.5,93.5),
        (37.5,92.5),(38.5,91.5),(39.5,91),(40,90),(41,90),(41,89.5),(41.5,89),(42,89),
        (42,89),(42,89.5),(41.5,90.5),(40.5,91.5),(40,92.5),(39,93.5),(38,95),(37,96),
        (36.5,96.5),(36,97.5),(35.5,98),(35,98.5),(35,99),(35,99),(35,99),(35.5,99),
        (36.5,99),(38,98.5),(39.5,98),(41,97),(43,96),(50.5,88),
    ]),
    stroke([ // 원본 event 7, 124점
        (38.5,82),(38,82),(37.5,82.5),(37,82.5),(36.5,82.5),(35.5,82.5),(35,82.5),(34,82.5),
        (33.5,83),(32.5,83.5),(32,84.5),(30.5,85),(29.5,86),(28.5,87.5),(27,88.5),(26,89.5),
        (25,90.5),(24.5,91),(24,92),(24,92.5),(24,92.5),(24.5,92.5),(26,92.5),(27.5,92),
        (29,91.5),(31,90.5),(33,89.5),(35,88),(37,86.5),(39.5,85),(41.5,83.5),(44,81.5),
        (46.5,80),(48.5,78.5),(50,77.5),(51,76.5),(52,76.5),(52.5,76),(52.5,76),(51.5,77),
        (50,79),(48,81),(46,83.5),(43,86),(41,88.5),(38.5,90.5),(36.5,92.5),(34.5,94.5),
        (33,96),(31.5,97.5),(30,99),(29.5,99.5),(29,100),(29,100.5),(29,100.5),(29,100.5),
        (29.5,100.5),(30.5,100),(31.5,99),(33,98.5),(34,97),(36,96),(37.5,95),(39,93.5),
        (41,92),(43,91),(45,89.5),(47,88),(48.5,87),(49.5,86),(50.5,85.5),(51,85.5),
        (51,85.5),(51,85.5),(51,86),(50,87),(48.5,88.5),(47,90),(45,92),(43,93.5),
        (41.5,95),(40,96.5),(38.5,98),(37.5,99.5),(36,100.5),(35.5,101.5),(35,102),(35,102.5),
        (35,102.5),(35,102.5),(36,102.5),(37,102.5),(38.5,101.5),(40,100.5),(41.5,99.5),(43.5,98.5),
        (45.5,97.5),(47.5,96),(49,95),(50.5,94),(52,93),(53,92),(54,91.5),(54.5,91),
        (54.5,91),(54.5,91),(54.5,91),(54.5,91),(54,91.5),(53,92.5),(52,93.5),(50.5,94.5),
        (49,95.5),(47,97),(45,98.5),(43.5,99.5),(42,100.5),(41,101.5),(39.5,102.5),(39,103.5),
        (38,104.5),(38,105),(38.5,105),(50,98),
    ]),
]
for (index, points) in device44Scratches.enumerated() {
    let result = CanvasPencilTextCorrection.gesture(for:points)
    print("IPAD44_TRACE event=\([1,3,5,7][index]) points=\(points.count) result=\(String(describing:result))")
    check(result == .erase,"실제 iPad44 지그재그 삭제 표본 \(index+1)")
    check(CanvasPencilTextCorrection.gesture(for:Array(points.reversed())) == .erase,
          "실제 표본의 역방향 삭제 \(index+1)")
    for angle: CGFloat in [-.pi/4,.pi/2,.pi] {
        let rotated = points.map { point in
            CGPoint(x:point.x*cos(angle)-point.y*sin(angle)+200,
                    y:point.x*sin(angle)+point.y*cos(angle)-90)
        }
        check(CanvasPencilTextCorrection.gesture(for:rotated) == .erase,
              "실제 표본의 회전·좌표 이동 불변 \(index+1)/\(angle)")
    }
}
for angle: CGFloat in [0,.pi/4,.pi/2] {
    for points in [stroke([(0,0),(96,0),(96,32),(0,32),(0,0)]),falseScratch] {
        let rotated = points.map { point in
            CGPoint(x:point.x*cos(angle)-point.y*sin(angle),y:point.x*sin(angle)+point.y*cos(angle))
        }
        check(CanvasPencilTextCorrection.gesture(for:rotated) == nil,
              "회전한 사각형·미세 반전 거부 \(angle)")
    }
}
check(CanvasPencilTextCorrection.gesture(for:scratch.map { CGPoint(x:$0.x*1e200,y:$0.y*1e200) }) == .erase,
      "유한한 큰 좌표의 공분산 overflow 방지")

print("검사 \(checks)개, 실패 \(failures)개")
if failures > 0 { exit(1) }

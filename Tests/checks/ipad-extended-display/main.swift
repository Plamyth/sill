import Foundation

func display(id: UInt32, name: String, width: Int = 1920, height: Int = 1080,
             isMain: Bool = false, role: String? = nil) -> DisplayInfo {
    DisplayInfo(id: id, name: name, width: width, height: height, isMain: isMain, role: role)
}

let owned = display(id: 42, name: "임의 이름", role: "ipadExtendedDesktop")
let main = display(id: 1, name: "iPad 확장 화면", isMain: true)
let unknown = display(id: 7, name: "Extended Desktop", role: "futureRole")
let wrongCase = display(id: 8, name: "iPad", role: "IPadExtendedDesktop")
let emptyRole = display(id: 9, name: "iPad", role: "")
let secondOwned = display(id: 43, name: "두 번째", role: "ipadExtendedDesktop")
let duplicateCandidateID = display(id: 42, name: "별도 모니터")
let duplicateOtherID = display(id: 1, name: "중복 주 모니터")
let client = ClientFixture()
let button = ButtonFixture(client: client)
var cases = 0

for ready in [false, true] {
    let inventories: [([DisplayInfo], DisplayInfo?)] = [
        ([], nil), ([main], nil), ([unknown], nil), ([wrongCase], nil), ([emptyRole], nil),
        ([owned], owned), ([main, unknown, owned], owned), ([owned, unknown, main], owned),
        ([owned, secondOwned], nil), ([owned, owned], nil),
        ([owned, duplicateCandidateID], nil), ([owned, main, duplicateOtherID], nil),
        ([main, unknown, wrongCase, emptyRole], nil)
    ]
    for (displays, expected) in inventories {
        client.displays = displays
        client.displaySelectionReady = ready
        client.submitted = []
        let accepted = ready ? expected : nil
        precondition(button.candidate == accepted, "후보를 잘못 선택했습니다.")
        button.selectExtendedDisplay()
        precondition(client.submitted == accepted.map { [$0] } ?? [], "현재 후보 이외의 선택을 전송했습니다.")
        cases += 1
    }
}

client.displays = [owned]
client.displaySelectionReady = true
client.active = .desktop
client.activeDisplayID = owned.id
precondition(button.selected, "선택 중인 확장 화면을 표시하지 않았습니다.")
client.active = .window
precondition(!button.selected, "창 스트림을 확장 화면 선택으로 표시했습니다.")
client.active = .desktop
client.activeDisplayID = main.id
precondition(!button.selected, "다른 모니터를 확장 화면 선택으로 표시했습니다.")

client.activeDisplayID = owned.id
precondition(button.candidate == owned)
client.displaySelectionReady = false
client.submitted = []
button.selectExtendedDisplay()
precondition(client.submitted.isEmpty && !button.selected, "오래된 inventory에서 전송했습니다.")
client.displaySelectionReady = true
precondition(button.candidate == owned)
client.displays = [main]
button.selectExtendedDisplay()
precondition(client.submitted.isEmpty, "사라진 후보를 전송했습니다.")

client.displays = [owned]
precondition(button.candidate == owned)
client.displays = [owned, secondOwned]
button.selectExtendedDisplay()
precondition(client.submitted.isEmpty, "누른 시점의 중복 role을 무시했습니다.")
client.displays = [owned, duplicateCandidateID]
button.selectExtendedDisplay()
precondition(client.submitted.isEmpty, "누른 시점의 중복 ID를 무시했습니다.")

let replacement = display(id: 90, name: "새 inventory 항목", width: 1366, height: 1024,
                          role: "ipadExtendedDesktop")
client.displays = [owned]
precondition(button.candidate == owned)
client.displays = [main, replacement]
button.selectExtendedDisplay()
precondition(client.submitted == [replacement], "현재 inventory의 원본 항목을 전달하지 않았습니다.")

let legacy = DisplayInfo(id: 10, name: "이전 Host", width: 1920, height: 1080, isMain: true)
precondition(legacy.role == nil, "기존 생성자의 nil 기본값이 달라졌습니다.")
let decoder = JSONDecoder()
let missingRole = try! decoder.decode(DisplayInfo.self,
    from: Data(#"{"id":11,"name":"iPad 확장 화면","width":1920,"height":1080,"isMain":true}"#.utf8))
precondition(missingRole.role == nil)
precondition(IPadExtendedDisplaySelection.candidate(displays: [missingRole], ready: true) == nil)
let decodedUnknown = try! decoder.decode(DisplayInfo.self, from: JSONEncoder().encode(unknown))
precondition(decodedUnknown.role == "futureRole", "알 수 없는 role 문자열을 보존하지 않았습니다.")
precondition(IPadExtendedDisplaySelection.candidate(displays: [decodedUnknown], ready: true) == nil)

if CommandLine.arguments.count > 1 {
    let data = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    let host = try! decoder.decode([DisplayInfo].self, from: data)
    precondition(host.count == 3 && host[0].role == nil && host[2].role == "futureRole")
    precondition(IPadExtendedDisplaySelection.candidate(displays: [host[0]], ready: true) == nil)
    precondition(IPadExtendedDisplaySelection.candidate(displays: [host[1]], ready: true) == host[1])
    precondition(IPadExtendedDisplaySelection.candidate(displays: [host[2]], ready: true) == nil)
    precondition(IPadExtendedDisplaySelection.candidate(displays: Array(host.prefix(2)), ready: true) == host[1])
    precondition(IPadExtendedDisplaySelection.candidate(displays: host, ready: true) == nil)
    print("Host 원담당의 실제 JSON fixture 해석과 중복 ID 거부 검사를 통과했습니다.")
}

checkToolbarBounds()
print("선택 fixture \(cases)개와 현재 목록 재확인·선택 상태 검사를 통과했습니다.")

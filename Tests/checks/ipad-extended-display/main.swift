import Foundation

let owned = DisplayInfo(id: 42, name: "임의 이름", role: "ipadExtendedDesktop")
let main = DisplayInfo(id: 1, name: "iPad 확장 화면", isMain: true)
let unknown = DisplayInfo(id: 7, name: "Extended Desktop", role: "futureRole")
let wrongCase = DisplayInfo(id: 8, name: "iPad", role: "IPadExtendedDesktop")
let emptyRole = DisplayInfo(id: 9, name: "iPad", role: "")
let secondOwned = DisplayInfo(id: 43, name: "두 번째", role: "ipadExtendedDesktop")
let duplicateCandidateID = DisplayInfo(id: 42, name: "별도 모니터")
let duplicateOtherID = DisplayInfo(id: 1, name: "중복 주 모니터")
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

let replacement = DisplayInfo(id: 90, name: "새 inventory 항목", width: 1366, height: 1024,
                              role: "ipadExtendedDesktop")
client.displays = [owned]
precondition(button.candidate == owned)
client.displays = [main, replacement]
button.selectExtendedDisplay()
precondition(client.submitted == [replacement], "현재 inventory의 원본 항목을 전달하지 않았습니다.")

checkToolbarBounds()
print("선택 fixture \(cases)개와 현재 목록 재확인·선택 상태 검사를 통과했습니다.")

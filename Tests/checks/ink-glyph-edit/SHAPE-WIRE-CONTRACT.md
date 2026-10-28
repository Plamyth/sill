# Shape wire 계약 대조와 다음 접합 조건

전체 shape 수용은 false다. glyph 순수 note 접합 a8810155는 별도 검수 가능하다. 원소유 e529975의 Kind 확장은 wire 변경 후보다. 현재 schemaVersion1/2를 유지하며 새 kind의 저장을 차단한다. schema3이나 downgrade를 임의 채택하지 않았다.

| 경계 | 실제 구현과 위험 | 현재 후보의 처리 |
| --- | --- | --- |
| 68a CanvasNode.Kind | note, box만 RawValue Codable로 해독. ellipse/line은 디코드 실패 | 기존 장치 수용 불가. 설치하지 않음 |
| CanvasScene schema | 1/2만 지원. 새 종류를 schema2로 표시하면 의미 버전이 같아 보임 | requireCompatibleNodeKinds로 새 종류 해독·제품 저장 명시 거부 |
| Proposal | line/box/ellipse의 좁은 기하 후보, sourceStrokeIds와 원본 drawing 유지 | box만 제품 확정. line/ellipse는 미리보기 및 거부 사유 |
| Files·로컬 캐시 | current.json 세대 저장, CAS 및 별도 recovery | 새 종류 외부 쓰기 전 거부. 기존 box·note의 pending/blocked/취소 보호 유지 |
| CanvasDiagramSnapshot | source를 flowchart TD로 만들고 모든 노드를 ["..."]로 표현 | 새 종류 snapshot을 명시 거부하여 상자 오표현 방지 |
| CanvasPeleView | snapshot.source를 ccrDiagram.update(payload)에 전달. 별도 kind 필드 없음 | 오류 보고와 diagram 비우기. 실제 WebKit 화면은 미검증 |
| Pele/bridge.js | payload.source를 번들 엔진에 전달하고 diagramID로 선택을 회신 | 엔진 자체에 새 노드 kind 의미 계약을 추가한 것이 아님 |
| iPad CanvasRelay.saveVaultCanvas | JSON·PNG를 /vault/canvas PUT으로 전송 | 네트워크 요청 작성 전 새 종류 거부 |
| relay f61f516 canvas-diagram.js | 모든 노드를 ["..."]로 투영. kind/schema 검사 없음 | 이 writer는 읽기만 함. 짝 relay 단위 필요 |
| relay f61f516 obsidian-vault.js | 종류 설명 box→상자, note→메모, 나머지→요소. saveCanvas는 identity/revision/크기만 확인 | 새 종류의 byte roundtrip만으로 의미 왕복 수용 불가 |

제품 포인터: iOSClient/CanvasBridge/CanvasModel.swift의 CanvasNode.Kind, CanvasScene.init(from:), requireCompatibleNodeKinds, CanvasDiagramSnapshot.init(scene:), CanvasFileWorkspace.save. CanvasStore.swift의 inkShapeCompatibilityMessage/confirmInkShape/persistScene/fileWorkspaceCanSync, CanvasRelay.swift의 saveVaultCanvas, CanvasWorkspace.swift의 sheet, CanvasInkShapeProposal.swift의 blockedReason. Pele 자원은 iOSClient/CanvasBridge/Pele/{bridge.js,diagram.html,pele.global.js}다.

relay 정본은 /Users/ambrion/Documents/ChatGPT/BT_CCR-Obsidian-relay, HEAD f61f51696aa5cd5b1973277a347ffca3f534fa26. 읽은 두 모듈의 SHA는 shape-wire-contract.json에 고정했다. 실행 중인 공유 relay 버전은 조작·조회하지 않았다. 이 HEAD를 설치 런타임 버전으로 주장하지 않는다.

다음 단위는 부모가 소유한 짝 relay의 schema/capability 정책 합의, 알 수 없는 kind/version의 명시 거부, ellipse와 선의 올바른 Mermaid/Pele 의미 표현 및 Obsidian 종류 설명, CAS·메모·native 원본·sourceStrokeIds·Undo/Redo 왕복, 구형68의 거부/보존 시험이다. 양쪽 exact commit/tree를 맞춘 뒤 guard를 해제한다. 선을 상자 노드의 라벨로 바꾸거나 타원을 box로 강제 변환해 왕복을 성공으로 만들지 않는다.

이번 실제 파일 성공 근거는 기존 box와 note에 한정한다. 선/타원의 기하 판별·미리보기 소스·SDK 컴파일과 wire 수용은 구분한다. UI 시각 수용·실제 iPad Pencil·새 native recognizer 성공·전체 MyScript/MS18 동등성은 남는다.

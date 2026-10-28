# scene3와 기존 릴레이의 접합 계약

2026-10-29 사용자가 전달한 부모의 구현 계약을 적용한 소스 후보다. 사용자 승인 범위는 기능 복각·Obsidian 연동·공식 통합이다. schema3의 세부값과 투영·capability 형식은 부모가 선택했다. 사용자가 이 세부값을 직접 확정했다고 표시하지 않는다. iPad writer 파일과 현재 서비스는 수정하지 않았다.

## 지원과 원본 보존

`relay/canvas-scene.js`의 `assertInkScene`은 sceneVersion 1·2·3을 받는다. 실제 필드명은 `schemaVersion`이다. 1·2의 node kind는 `note`, `box`다. 3은 여기에 `ellipse`, `line`을 추가한다. 3의 잉크는 2와 같은 penSettings·style·points 검증을 사용한다. packet의 schema1과 scene의 schema3은 별개이며 packet 형식을 올리지 않는다.

알 수 없는 버전·종류와 누락된 scene 버전은 저장 전에 거부한다. 읽을 때 미지원 원본이 있으면 원본·노트·해시를 수정하지 않고 409로 거부한다. 새 필드를 제거하거나 새 종류를 box로 바꾸지 않는다. scene3의 frame x·y·width·height와 rotationDegrees는 유한 값과 기본 계산 범위를 확인하며 값 자체를 정규화하지 않는다. 선의 끝점 방향·최소 크기·음수 치수·회전 좌표계의 최종 의미는 iPad writer 계약으로 확정해야 한다. 릴레이는 이 후보에서 새 geometry 필드를 만들지 않는다.

`relay/obsidian-vault.js`의 `saveCanvas`와 `#canvasSnapshot`은 공통 scene 검증을 호출한다. JSON과 PNG는 원래 바이트와 SHA로 보관한다. scene3에서 1·2로 낮추는 덮어쓰기는 409로 거부한다. Markdown의 scene3 요소에는 종류, frame, 명시된 rotationDegrees가 들어간다. 기존 1·2 note·box Markdown은 원본 릴레이의 동일 입력 SHA와 일치했다. memo 경계·CAS·한도·출처 asset은 기존 경로를 사용한다.

`relay/server.js`의 packet parse와 `relay/codex-delivery.js`의 `sceneContext`는 같은 validator를 사용한다. AI 문맥은 원래 nodes와 schemaVersion을 그대로 담는다. agent revision 저장은 proposedNodes와 nodeEdits.expected의 종류를 원래 scene 버전에 맞춰 검증한다. 이 경로는 scene 원본을 바꾸지 않는다. iPad writer의 그리기·glyph·agent 적용 단계에서도 schema3 유지가 필요하다.

## 지정 capability endpoint

기존 `X-Canvas-Token`으로 인증하는 `GET /vault/canvas/capabilities`를 구현했다. 새 인증·Host 프로토콜·서비스는 만들지 않았다. 응답은 아래 계약과 정확히 같다. vault 경로가 아직 설정되지 않아도 서버의 형식 지원을 확인할 수 있다. 기존 `/delivery/ready` 응답은 변경하지 않았다.

```json
{"schema":"ccr.canvas-capabilities/v1","sceneSchemaVersions":[1,2,3],"nodeKinds":["note","box","ellipse","line"],"diagramProjection":"ccr.diagram-shapes/v1"}
```

iPad writer의 `CanvasRelay.swift`에 있는 `CanvasSceneCapabilities.require`와 `requireSceneSupport`가 짝이다. `saveVaultCanvas` 및 `send`에서 scene3의 PUT·POST 전에 정확한 schema·projection, 지원 버전과 모든 실제 node kind를 확인한다. 404·필드 누락·해독 실패·지원 거부에는 쓰기를 보내지 않고 미동기화 원본을 보존한다. scene1·2는 구형 endpoint 404와 관계없이 기존 경로를 유지한다. writer 소스는 읽기만 했고 해당 담당이 별도 소유한다. 실제 iPad 실행·설치 수용은 이 후보의 검증에 포함하지 않는다.

원본 f61f516의 vault 경로는 scene3를 받아도 validator를 호출하지 않아 저장 성공과 Mermaid 사각형 오표시가 가능했다. `relay-integration-evidence/old-vault-scene3-probe.json`은 사용자 vault 대신 격리 fixture로 이 간극을 재현한 근거다. 구형 서버의 200 응답만으로 scene3 수용을 판단할 수 없다. capability 응답은 현재 소스 후보의 계약이며 실행 서비스가 지원한다는 뜻이 아니다.

## 동일 Mermaid 투영과 남은 수용

`relay/canvas-diagram.js`의 `canvasMermaid`가 부모의 `DIAGRAM-PROJECTION-v1.md`를 구현한다. note·box의 기존 선언을 유지한다. ellipse는 원래 nUUID 선언과 고정 `classDef ccrEllipse rx:50%,ry:50%`를 사용한다. line은 원래 nUUID와 표시 전용 xUUID의 숨은 끝점 사이에 `---` 무화살촉 선을 만든다. xUUID는 JSON·wire에 추가하지 않는다. 실제 관계는 기존 nUUID를 계속 사용한다. 배열 순서·접힘·escaping·한도와 원본 node 필드를 유지한다. 사용자 입력을 style 또는 class 명령으로 넣지 않는다. 원래 wire의 노드 512개·관계 1,024개 한도와 함께 visible nodes + line helper ≤512, visible links + line primitive edge ≤1,024 표시 한도를 적용한다.

Markdown에는 `ccr.diagram-shapes/v1`과 자동 배치 모드를 명시한다. Mermaid 자동 배치는 원본 frame·rotation의 좌표 재현과 다르다. JSON과 Markdown의 기하 정보는 원본 위치·크기·회전을 보존한다. PNG는 iPad가 제공한 원본 바이트만 보관하며 릴레이가 재렌더하지 않는다.

`relay/test-input/scene3-projection/`에는 부모의 실제 Swift writer가 생성한 합성 scene와 snapshot을 원문 바이트로 담았다. provenance의 파일 SHA를 확인하고 릴레이 Mermaid가 실제 writer의 source와 UTF-8 바이트까지 일치하는지 검사한다. 그 같은 scene JSON도 저장·재열기하여 정확히 보존되는지 확인한다. 부모의 별도 macOS WKWebView 근거에는 중심/모서리 isPointInFill, rx·ry 50%, 숨은 두 끝점, 실제 무화살촉 path와 원래 UUID 선택이 기록됐다. 이 worker가 WebKit을 재실행한 것은 아니며 원본 근거 경로와 SHA를 provenance에 연결했다.

이 후보의 PNG 검사는 synthetic PNG의 파일 왕복이다. 실제 iPad PNG의 타원·선·회전 렌더와 손가락·Pencil 선택, 설치·실서비스 수용은 별도다. 독립 검수와 공식 통합도 부모가 exact commit/tree로 마쳐야 한다. 이 작업은 서버·vault·기기·Host·키·권한을 변경하지 않았다.

부모의 별도 `schema3-native-verification.json` 관측에는 WebKit 검사는 통과했지만 relay 검사는 exit -5로 남아 있다. 해당 로그는 `RelayScene3Check.swift:53`의 `httpBody!` 검사에서 nil을 해제하다 실패했다. 이 worker는 그 검사를 재실행하거나 성공으로 대체하지 않았다. writer의 실제 URLSession 수용은 부모가 자신의 수정·영수증으로 마쳐야 한다. 이 후보의 인메모리 HTTP handler와 파일 왕복 성공은 그와 구분한다.

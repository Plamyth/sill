# scene3 및 ccr.diagram-shapes/v1 짝 계약

2026-10-29 사용자 요구를 구현하기 위해 조율 담당이 선택한 계약으로 scene 내부 schemaVersion3에서만 line/ellipse를 허용한다.1/2는 note/box와 기존 잉크를 계속 읽는다. 알 수 없는 version/kind는 명시 거부한다. packet/outbox/recovery 등의 독립 schema1은 바꾸지 않는다. 생성 시3승격, 이후 일반 그리기·펜 설정·glyph 삭제/Undo·원격 제안/수정은 기존3을 보존한다. 원본 native drawing/frame/rotation/sourceStrokeIds는 그대로 둔다.

## 지원 확인

schema3을 서버에 쓰기 전에 GET `/vault/canvas/capabilities`(기존 X-Canvas-Token) 응답을 검사한다. 응답은 `{"schema":"ccr.canvas-capabilities/v1","sceneSchemaVersions":[1,2,3],"nodeKinds":["note","box","ellipse","line"],"diagramProjection":"ccr.diagram-shapes/v1"}`이다. 정확한 schema/projection, sceneVersion, 실제 모든 node kind를 확인한다.404/지원 누락/해독 오류면 PUT `/vault/canvas` 및 POST `/packets`를 실행하지 않는다. 지원 응답 뒤415/409 등도 실패로 유지한다. 기존 Workspace는 동기화 대기를 표시하고 성공 SHA를 갱신하지 않는다.1/2 경로는 이 새 endpoint가 없어도 유지한다. 실제 짝 relay 수용은 부모의 exact commit과 대조해야 한다. 현재 원본 f61f516 서버/데이터는 변경하지 않았다.

## 동일 정적 Mermaid 생성 규칙

입력 노드와 관계의 원래 배열 순서, 기존 visibility·UUID·label escaping을 유지한다. nodeID는 `n`+소문자 하이픈 없는 UUID다. note/box는 기존 `["label"]` 선언을 유지한다. ellipse는 같은 선언 뒤 `class nUUID ccrEllipse`를 추가한다. line은 `nUUID[" "]`, `xUUID[" "]`, `nUUID ---|"label 또는 직선"| xUUID`, `class nUUID,xUUID ccrLineEndpoint`를 순서대로 생성한다. xUUID는 도형이 아닌 표시 전용 두 번째 끝점이다. 실제 wire node는 하나이며 UUID/frame/rotation/출처를 복제·변경하지 않는다.

노드 선언 뒤 ellipse가 있으면 `classDef ccrEllipse rx:50%,ry:50%`, line이 있으면 `classDef ccrLineEndpoint fill:none,stroke:none`를 각 한 번 추가한다. 그 뒤 기존 관계 선언을 추가한다. 원래 label이 비어 있는 note/box/ellipse는 `이름 없는 요소`, line의 선 라벨은 `직선`이다. label의 ASCII 비영숫자·공백 이외 문자를 `#정수;`로 escape한다. 사용자 입력을 class/style/DSL 명령에 넣지 않는다. 관계 endpoint는 원래 nUUID를 사용한다. line의 sourceStrokeIds·frame·rotation은 JSON에 원래 값으로 남는다.

이는 자동 배치 다이어그램이다. native 원본의 회전·크기·위치를 그대로 재현하는 좌표 투영이 아니다. 선은 실제 무화살촉 edge/path이며 두 보이지 않는 끝점은 상자로 표시하지 않는다. 타원의 CSS는 실제 WebKit에서 중심/모서리 isPointInFill·computed style로 확인한다. 단위 없는 rx값이나 parse 성공만으로 시각 수용을 주장하지 않는다.

Pele bridge payload에는 각 실제 node의 kind를 추가하고, line일 때만 xUUID를 파생한다. 렌더된 endpoint와 primitive edge의 선택은 원래 nUUID/실제 UUID로 돌아온다. scene3 JSON node 목록에 xUUID를 저장하지 않는다. SVG 안전 검사·원래 note/box 선택·stale 세대 검사는 유지한다.

원본 모드 NodeTile은 실제 도형 높이2pt와 선택 프레임을 분리해 최소44/zoom 캔버스 단위의 layout/contentShape를 확보한 뒤 같은 중심을 기준으로 회전한다. contentShape만 원래2pt bounds 밖으로 늘리는 방식에 의존하지 않는다. iPad 실제 손가락/Pencil 터치 수용은 아직 하지 않았다.

표시 한도는 실제 visible nodes + line 표시 끝점 수 ≤512, visible links + line primitive edge 수 ≤1024다. Snapshot에서 수를 계산하고 bridge가 parse 모델과 SVG의 node/edge 수를 대조한다. helper를 제외한 원본 scene 한도도 유지한다. 원래 wire의 nodes/links 배열에 표시 helper를 추가하지 않는다.

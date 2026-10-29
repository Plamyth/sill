# 같은 원본 카드의 그룹·하위 지도

기준은 f09daa176fb9ff8ff45dcb30389eb06f33ea2b40/treebd2347c35def444ca01dea8ec328c19e0ecffff0다. 독립 codex/ipad-group-submap-20261029에서만 변경하며 부모가 공식 통합한다. MarginNote Mac의 실제 그룹/축소 ON·OFF와 안정 ID·순서·원문/잉크 보존 자료를 대조했다. iPad 원앱·실기기·Pencil·전체 MarginNote 동등성 수용이 아니다.

## 사용자 흐름과 정본

그림판의 기존 선택 모드에서 카드를 고른 뒤 ‘그룹 · 하위 지도 → 선택 카드부터 그룹 준비’를 누른다. 다음 카드를 선택해 순서에 추가하고 ‘이 순서로 그룹 만들기’를 누른다. 한 카드 그룹도 지원하며 최대20개는 기존 병합 선택 한도를 재사용한 CCR 계약이다. 일반 메모의 원래 ID·본문·vaultNote·sourceStrokeIds·기존 댓글·연결·native drawing은 그대로이고 새 box 테두리만 같은 자리에 추가한다. 선택한 순서는 새 일반 연결선의 번호로 보존한다. 원문을 복제하거나 그룹 제목에 인용을 합쳐 넣지 않는다.

그룹을 선택해 ‘하위 지도로 접기’를 누르면 메인에 요약 box만 남는다. 같은 메뉴의 하위 지도 목록에서 들어가면 같은 멤버 ID와 내부 관계만 보이고 ‘전체 지도로 돌아가기’로 복귀한다. 원본 잉크는 공통 바탕으로 유지하며 하위 지도에 별도 잉크 복사본을 만들지 않는다. 메인에서 그룹을 다시 선택해 ‘그룹 펼치기’로 원래 카드들을 표시한다. 기존 그림 표시와 Pele 투영은 같은 멤버십을 사용한다. 입력 모드를 바꾸거나 다른 페이지로 전환하면 열린 하위 지도 뷰를 닫는다. 편집·저장 가능한 객체는 언제나 원본 Scene이다.

JSON 정본은 기존 필드만 쓴다.

- container: `CanvasNode.kind = box`, 일반 제목 text, `isCollapsed`는 요약/하위 지도 표시 상태. 원문 참조나 획 소유권 없음.
- 표식: container의 annotation 하나. 예약 author `ccr.sill.group/v1`, 고정 text `같은 원본 카드의 그룹입니다. 번호가 있는 소속 연결이 카드 순서입니다.`
- 소속: `kind = general`, from = container ID, to = 기존 메모 ID, label = `ccr.sill.group/v1 · 1`부터 연속 번호. 이것만 순서 있는 소속 정본이며 별도 멤버 배열/DB/트리가 없다.
- 열린 하위 지도·임시 선택 draft·메인 viewport는 Store의 일시 뷰 상태다. 파일을 새로 열면 메인에서 같은 접힌 그룹 목록을 다시 해석한다.

사람과 AI는 같은 Scene JSON의 ID·번호·제목·isCollapsed·댓글을 수정한다. 기존 Files/Obsidian API와 전체 문서 저장이 그 JSON을 그대로 보관한다. 새 server API·provider·scene kind·JSON schema·별도 Markdown 정본은 없다. 원래 일반 parentChild는 변경하지 않는다. 구형 소비자가 새로운 그룹 표시 의미를 해석한다는 호환성은 주장하지 않는다.

## 표시 투영과 원본 보존

`cardTagDisplayScene`은 값형 표시 복사본이며 원본 scene에 대입하지 않는다. 하위 지도에서는 이 복사본의 노드 순서만 소속 번호에 맞춘다. native 그림의 원래 카드 좌표와 저장 배열은 그대로다. 메뉴의 번호 목록도 같은 ID를 선택한다. Pele 브리지는 error/select 메시지만 처리하고, 그래프 반환값으로 scene을 교체하는 경로가 없다. 기존 inspector·댓글·원문 편집은 canonical scene의 원래 ID를 사용한다. 하위 지도 뷰 세대를 WebView identity에 포함해 페이지/뷰 ABA 뒤의 이전 surface를 재사용하지 않는다.

그룹 요약 표시 때 카드뿐 아니라 관련 annotation도 같은 가시성 교집합으로 렌더한다. JSON·native ink·숨은 카드/링크/댓글은 여전히 전체 source에 남는다. 기존 hierarchy 접기 버튼은 그룹 표식을 부모·자식 구조로 해석하지 않으며, 거부 시 전체 document revision과 command owner도 바꾸지 않는다. 실제 Store 댓글 편집/Undo·외부 JSON/Files 수정·페이지 복귀 검사에서 숨은 배열의 정규 JSON 바이트와 원본 ink를 대조한다.

## 지원 경계와 보호

중첩 그룹, 여러 그룹의 동일 멤버, 그룹·멤버에 parentChild가 연결된 구조, 순환/자기 소속, 누락/중복 ID·번호·표식, 미지원 표식 버전은 거부한다. 기존 parentChild를 그룹 소속으로 바꾸거나 원앱 표본의 루트 중복을 데이터 규칙으로 복제하지 않는다. 기존 부모·자식 연결/그래프 편집/에이전트 패치도 그룹 소속을 손상시키는 후보는 설치하지 않는다. 손상된 외부 데이터는 지우거나 번호를 다시 붙여 복구하지 않는다. 그룹 명령을 막고 원본 구조와 오류를 표시한다. 그룹으로 해석할 수 없는 입력을 숨겨서 정상 그룹이라고 보고하지 않는다.

선택 draft는 기존 병합의 scene SHA·명시 카드 추가를 재사용한다. Store의 장면/선택 세대, 문서/페이지 ID와 하위 지도 뷰 세대를 결속한다. 페이지·장면·선택 ABA 뒤의 확인과 오래된 메뉴 callback을 적용하지 않는다. native 획 사용·입력 모드 변경·장면 변경은 draft를 취소한다. 기존 입력·미확인 저장·typed409·document conflict·Files conflict barrier가 계속 적용된다.

그룹 생성/접기/펴기는 `persistScene`이 성공한 뒤 설치하고 기존 그래프 Undo/Redo를 기록한다. IO 실패는 원문과 draft를 유지한다. Undo/Redo는 CCR의 명시 계약이며, 원앱의 하위 지도 축소 Undo 시도를 성공 관측으로 바꾸지 않는다. 명시 그룹 해제/중첩/그룹 통째 이동/자동 재배치는 이번 근거에서 구현하지 않는다. 원래 카드 이동 후 container frame을 자동 재배치하는 기능도 추가하지 않았다.

## 소유와 접합

Store의 그룹 명령 블록과 `sceneDidChange`/선택·입력 guard에만 접합한다. Workspace에서는 도구 메뉴의 CanvasGroupMenu와 그림 표시의 breadcrumb/그룹 가시성만 사용한다. PDF Reader/Excerpt/Store의 PDF 절, Workspace PDF sheet는 바꾸지 않는다. 부모의 CanvasDocument 새 페이지 연산, Store `changeDocumentPage`, Workspace `documentPagesSheet`도 바꾸지 않는다. 기존 페이지 전환·복제 API를 검사의 소비자로만 호출한다. PencilCanvas/Host/키·음성/설치/GUI/기기/일반 서비스/실 vault 변경0이다.

## 검사 근거

기존 card-merge 실행기의 --group-submap만 사용해 실제 Model/Store/PKDrawing·격리 Files·새 Swift 프로세스·전체 문서 페이지 경계를 검사한다. PNG는 기존1px preview fixture이며 시각 수용이 아니다. 기존 전체385/PDF/서버 회귀를 반복하지 않는다. 별도 group-relay.cjs는 기존 ObsidianVault 모듈로 own vault에 저장·새 인스턴스 재열기·역방향 JSON 수정·CAS 거부·자산/원본 보존을 검사하고 fixture를 제거한다. Mini는 작업별 한시 입력/정리 영수증을 사용하며 listener0이다. 정확 결과·실패 수리·소스 해시는 전용 evidence 영수증에 연결한다.

## 공식 후속 결합

독립 구현은 f09 기준78344fffa79d5c55593233de603fa1c987568523으로 먼저 확정했다. 이후 사용자 지정 공식5fcb42cc1a1430a64210dd5d89c930a61fd8a0da/tree5c63f332fd6786adbd4291461c9f5b83e83f34c5를 같은 소유 브랜치에 의미 병합한다. Store/Workspace는 텍스트 충돌 없이 합쳐졌고, PDF 보기 저장 수리와 빈 페이지·순서 연산 본문은 공식과 바이트 대조한다. 기존 card-merge native 검사기는 새 Store의 PDF 타입 의존성 때문에 정식 codec과 Reader의 기존 native 부분을 포함하도록만 조정한다. PDF 제품 코드는 별도로 바꾸지 않는다. 그룹/문서/PDF 복구 barrier를 합집합으로 유지하고 새 결합부만 검사한다. 설치/실기기 수용으로 표시하지 않는다.

## 전면 한글 표시 후속

독립 수용된 e282eba8의 소속·저장·가시성 계약은 유지한다. inspector의 예약 author v1은 ‘그룹 정보’, 검증된 소속 연결은 ‘그룹 소속 1’처럼 표시하는 순수 formatter를 기존 Model에 둔다. Workspace의 주석 이름·링크 접근성 이름과 CanvasDiagramSnapshot의 기존 관계 이름 경로가 같은 formatter를 쓴다. 일반 링크의 화면 text 렌더는 원래 없으므로 추가하지 않는다. 소속 링크가 기존 투영에서 숨겨지는 조건도 바꾸지 않는다.

원본 author/linkPrefix·번호·ID·JSON·native ink는 수정하지 않는다. 일반 사용자 author/link/comment와 NFD·CRLF는 그대로 표시하고, 미지원 버전·잘못된 번호·표식 없는 관계를 정상 그룹처럼 다시 이름 붙이거나 자동 정규화하지 않는다. 기존 카드 태그의 한국어 표시도 그대로다. 독립 60조건·전체 SDK는 반복하지 않고 실제 e282 격리 JSON으로 표시/A11y·일반 문구·손상 자료·바이트 불변의 작은 native 확인과 Workspace 구문 확인만 한다. GUI·기기·설치·질문·알림은 실행하지 않는다.

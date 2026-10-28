# 일반 Markdown·PDF 발췌 노트의 명시 복구 client

기준은 공식9646469ba63b2ed6a65c61a6384f541222dd5dee/tree4e8b7abf92485050610da334d6ec0166094adacb다. 별도 codex/ipad-note-conflict-product-20261029 / note-conflict-product-source에서만 수정한다. 이전 glyph WT, 부모 integration, 서버 WT는 수정하지 않는다.

서버 f6e7b7d52fd1ca8d768286123b260c1e0c351f00/tree783ff92c98f6f7005e28ecd99b3c3287241998b2의 정확 NOTE-RECONCILIATION-CONTRACT.md와 작은 실제 wire-example.json을 소비한다. 예제는 producer Git 객체의 바이트·SHA를 provenance.json에 고정했다. 사용자 자료나 큰 서버 소스 사본은 포함하지 않는다. 부모가 기존 승인 목표의 복구 P2 해결을 위해 채택한 DTO이며 사용자가 개별 필드 자체를 직접 확정했다고 쓰지 않는다. producer 독립 SOURCE_CLEAR 전달은 별도이며 client 수용을 대신하지 않는다.

## 제품 흐름과 보존

기존 Obsidian 노트 sheet 내부의 ‘일반 노트 충돌 자료 비교·명시 복구’에서 현재/기준/외부 변경/제안 원문·SHA와 iPad 미저장 입력/문단 작업 ID를 비교한다. 기존 sheet를 재사용해 새 중첩 sheet를 만들지 않는다. 한글 확인에서 keepCurrent 또는 useDisplaced를 선택하면 전용 note/conflict PUT을 보낸 뒤 기존 note GET의 원문 bytes/SHA가 일치해야 복귀한다. body는 canonical 소문자 recoveryID 문자열·다섯 필드/null의 expected·decision 세 필드뿐이다. raw 오류 문구/복구 경로를 의미 분기로 파싱하지 않는다.

일반 material의 validNote와 UTF-8/1MiB/실제 원문 SHA, 경로, null 쌍, history 상한을 확인한다. 응답은8MiB, 로컬 choice는12MiB 한도다. Canvas의 sceneJSON/PNG 필수 검사를 일반 노트에 붙이지 않으며, 반대로 CCR Canvas 디렉터리/case 별칭과 managed frontmatter 후보를 일반 API로 보내지 않는다. 서버의 inode·소유자·FD 경계는 서버 검사이며 client가 대신 입증했다고 쓰지 않는다. PDF 발췌는 현재 존재하는 상대 Markdown과 block anchor를 대상으로 한다. PDF 바이너리·주석 원본 취득이나 전체 PDF 기능 수용이 아니다.

서버 쓰기 전에 기존 base/draft/submittedText 및 block pending의 operationId를 모두 NoteConflictLocalState로 저장하고 재읽기한다. 선택 원문과 기존 입력의 의미를 섞지 않는다. 서버 조정과 note GET이 확인되면 원래 입력은 별도 보존하고 기존 편집기를 선택 원문으로 재열며, 로컬 choice의 completed 기록 뒤에만 차단을 해제한다. ‘보존 입력을 새 원문 위 미저장 초안으로 열기’는 명시 동작이다. whole-note draft는 그대로 초안으로, 문단 draft는 **현재 선택 원문의 같은 anchor가 여전히 유효할 때만** 기존 Markdown block replacement를 재사용해 미저장 초안으로 연다. 예전 block operationId는 archive에서 볼 수 있지만 새 base에 자동 재전송하지 않는다. anchor가 없거나 중복/지원불가이면 명시 거부하고 보존 텍스트를 계속 표시한다.

새 선택은 이전 완료 choice도 먼저 허용된 attempt 파일에 보존한다. 미완료 다른 note/context를 덮지 않는다. 409는 refreshRequired로 남기고 새 expected/materials를 읽기 전 자동 재시도하지 않는다. GET404는 pending held/draft를 해제하지 않는다. 성공 응답 유실은 같은 ID/decision/원래 expected를 사용자가 명시 확인한다. 새 타이핑·scene ABA·연결 세대·닫힘 후 늦은 응답은 note/draft를 교체하지 않는다. 재시작은 기존 note/block 복구 레코드와 같은 scene/address의 local choice를 소비하며 자동 쓰기나 조정 완료 추정은 없다.

## 경로·소유권

정상 Application Support/CanvasConflictRecovery/, isolated는 현재 UUID state/CanvasConflictRecovery/를 재사용한다. 추가 허용 이름은 NoteConflictChoice.json, NoteConflictLocal-<canonical lowercase UUID>.json, NoteConflictAttempt-<canonical lowercase UUID>.json 세 종류뿐이다. 다른 UUID/root는 여전히 거부하며 기존 Canvas 파일 이름과 primitive descriptor/no-follow IO를 바꾸지 않는다. 기존 Ohm ORIGINALS snapshot은 디렉터리 전체를 보호하므로 새 파일도 포함한다. Scripts와 writeRuntimeReceipt/loaded codeImages 함수는 수정하지 않는다. key·Host·기기·권한·설치·사용자 vault 변경은0이다.

## 재현과 수용 범위

`python3 Tests/checks/note-conflict/run.py --isolated --sdk-check --output <storage-route 검증 외장>`

실제 DEBUG CanvasRuntime.launch/CanvasLocalFile/Store/Relay를 native SDK27로 컴파일하고 실제 process --ccr-test-runtime/context/embedded source identity로 실행한다. UI async 함수는 원본을 수정 없이 추출하며 UI 상태 저장과 URLProtocol transport만 fixture다. 일반 두 선택·정확 query/body·unsafe/Canvas 거부·SHA/readback/stale 거부·ACK 유실·재시작·초안 보존/수동 재개·PDF Markdown block ID 보존·늦은 callback·네이티브 directory IO 거부 및 서버 실제 예제 호환을 검사한다. 전체 iOS27 제품 타입 검사와 정상 앱 support의 synthetic scene/outbox/Canvas·Note 복구 파일 전후 해시도 같은 실행에 기록한다.

실제 HTTP/화면/설치/Pencil/전체 MyScript·MarginNote 완료는 false다. 이전 Canvas paired HTTP CLEAR를 이 새 일반 노트 단위에 재사용해 완료로 표시하지 않는다. 사용자 승인 범위의 source 구현과 필수 검사·커밋까지만 수행하고 공식 통합·새 paired HTTP 및 독립 검수는 부모 경로로 반환한다. Pstack의 exact contract/caller·실패 경계 검증과 Ponytail의 기존 sheet/복구/파일 primitive/Markdown block 재사용을 적용한다. 새 provider·모델·의존성·ARENA·순정 Goal은 없다.

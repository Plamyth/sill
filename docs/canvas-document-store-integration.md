# 복수 페이지 문서 Store·UI 접합

이 단위의 원래 기준은 `b1b7e30efb32a615eae847cbf8280983fb3b0982` / `e7ce8079e3ea3753814be615a78ade2f6914d71b`다. API 소유 단위 `422cefdad52667c5e73eb503e06c8287dbf4b99c`를 그대로 소비하고, 독립 수용된 저장 재사용과 PDF 목차를 포함한 공식 `486b2e02ad9178a37617a2e1cae6e660c7d97303`을 이 writer 브랜치에 병합했다. 기존 저장 원본 WT `782978d`, 저장 재사용 WT `ded8020`은 수정하지 않았다. 공식 integration 쓰기·push·설치·GUI·기기·Host·8791 서비스 전환은 이 단위의 작업이 아니다.

소유 매핑을 정정한다. **Store·Workspace·Pencil/Undo 접합은 Helm**, **CanvasRelay.swift·CanvasDocumentRelay.swift·DTO/HTTP·프로젝트 등록은 Laplace**가 소유한다. 과거 저장 단위 HANDOFF의 ‘Store owner Laplace’는 잘못된 매핑이다. 해당 고정 영수증을 소급 변경하지 않고 여기서 바로잡는다. 서버와 원본 서비스는 Galileo/부모 소유이며 이 writer는 우회 구현하지 않는다.

## 원본과 mutation 경계

Store가 가변 `CanvasDocument` 한 개를 소유한다. `scene`은 `document.activePage`의 computed 투영이며 별도 가변 activeScene 저장본이 아니다. `storedDrawing`과 PKCanvasView는 기존 native 표시 캐시다. 페이지 전환은 검증된 전체 문서만 한 번 설치한 뒤 표시 캐시를 바꾼다. 불변 graph Undo 전후 자료·native UndoManager·glyph/spacing 편집 이력은 문서/페이지별 소유자를 가진다.

| 기존 표면 | 새 책임과 보존 조건 |
|---|---|
| `scene = next`, `scene.field`, 배열 원소 쓰기, mutating scene 메서드 | `updateActivePageForEditing`이 같은 선택 페이지 ID만 내부에서 갱신한다. 외부 decode·파일 수용 API가 아니며 이 짧은 같은 MainActor turn 안에서 drawingBase64/strokes 중간 불일치를 거부하지 않는다. document revision을 전진시키고 기존 didSet의 선택·콜백 무효화와 지연 저장을 재사용한다. |
| `drawing` setter, `updateDrawing`, `installInkTextScene` | 기존 native 원본과 투영 갱신 및 Undo 무효화를 유지한다. 전체 문서 작업/미조정 상태가 입력을 소유한 동안 늦은 native 쓰기는 적용하지 않는다. |
| 펜/도형/수식/글자 삭제/간격/카드 확정, 댓글·연결/크기·회전/graph Undo | 기존 후보와 persistence-before-install 순서를 유지한다. `persistScene(candidate)`는 문서 모드에서 선택 후보를 포함한 **전체 Document**를 검증해 캐시에 쓴다. 기존 scene schema3을 낮추지 않는다. |
| linked note/PDF 발췌/review·tag의 내부 scene 쓰기 | 기존 note scene/connection/editor generation과 복구 원장을 유지한다. 페이지 전환은 해당 입력·초안·시도·미확인 원장 때문에 차단된다. 자동 note 역수신도 문서 전체 작업 중에는 새 페이지를 변경하지 않는다. |
| 외부 JSON/Files/relay ingress | 전체 Document decoder/native 검증을 사용한다. 새 문서 decode 실패를 legacy scene로 재해석하지 않는다. 다른 ID의 scene를 새 문서 안에 설치하거나 선택 페이지만 scene API로 보내지 않는다. 중복 JSON 키의 raw byte 방어는 부모의 별도 수리 단위와 union할 대상이며 여기서 중복 구현하지 않았다. |
| 지연 인식/검색/glyph/spacing/수식·filePreview | 문서 session/UUID/전체 SHA/선택 페이지/revision/pageEpoch와 요청·기존 selection generation을 await 뒤 다시 확인한다. A→B→A의 이전 결과는 수용하지 않는다. |
| PNG/PDF·Pele | 현재 페이지의 파생 표시/내보내기다. UI에 현재 페이지라고 표시한다. 전체 문서 원본·자산 저장이나 숨은 페이지 서버 전송의 대용물이 아니다. |

외부 입력과 전체 persistence는 여전히 strict validation을 수행한다. `document` 바깥에서 원본을 유실시키는 작업용 shadow scene나 별도 DB는 만들지 않았다. 기본 문서 형식/scene/packet wire의 버전 숫자를 변경하지 않았다.

## 저장과 페이지 전환

legacy와 Document 진입을 분리한다. 기존 Files 메뉴는 legacy scene 전용이다. 새 ‘여러 페이지 문서’ 메뉴는 전체 문서 시작, 전체 Files 폴더 연결·목록·열기, 페이지 선택·복제, 전체 저장·외부 변경 재열기를 연결한다. `ded8020`의 독립 SOURCE_CLEAR 및 공식486 통합을 받은 뒤 이 제품 진입을 활성화했다. 소스 접합과 설치·실제 UI 수용은 별개다.

`CanvasDocumentSource.json`은 기존 scene 파일과 다른 앱 내부 전체 문서 캐시다. `ccr.canvas-document-source/v1` 외곽에 kind/document/Files binding/typed sync 상태를 한 atomic write/readback으로 보관한다. DEBUG isolated runtime은 기존 StateFile exact allowlist의 이 고정 이름만 추가한다. Ohm의 runtimeReceipt/codeImages 함수나 adapter를 수정하지 않는다. 설치 보호 snapshot 소비자는 이 **새 캐시 파일**의 부재/추가/변경도 보호해야 한다.

새 Document는 복구본부터 시작할 수 있지만 다른 문서/legacy로 떠나기 전에는 현재 전체 원본이 Files에 저장되어야 한다. Files binding은 bookmark·document ID·전체 head token·saved document SHA를 갖는다. 원본 디렉터리 identity/경합/전체 페이지·preview/native drawing 검증과 마지막 head 교체는 독립 수용된 `CanvasDocumentFiles`를 그대로 사용한다. 저장 의도가 없어지는 no-op과 안정 base 재사용도 그 구현을 소비한다. GC·기존 recovery 삭제·물리 저장량 상한 해결은 이 단위의 주장에 포함하지 않는다.

선택/복제는 기존 전체 원본을 보존하고, 모든 페이지 preview를 렌더한 뒤 snapshot/취소를 다시 확인하고, 전체 Files CAS 저장·readback, 전체 cache atomic write/readback이 끝난 뒤에만 메모리를 설치한다. 실패 시 이전 페이지/선택/Undo를 유지한다. Files 교체 후 cache 쓰기 실패는 새 head와 옛 cache binding 차이로 재열기가 보류된다. 이를 저장 성공이나 자동 rollback으로 표시하지 않는다. 확정 로컬 본문이 마지막 저장 SHA와 같은 경우에만 명시 Files 재열기로 외부 전체 원본을 수용한다. 로컬 수정·미확인 발행·숨은 복구가 있으면 바꾸지 않는다. 보존용 전체 JSON 사본 내보내기는 보류를 해제하거나 원래 바인딩을 변경하지 않는다.

페이지 전환은 Pencil tool/trace, 라쏘 인식 요청·제안, IME/Scribble/교정·댓글·태그·카드 입력, 드래그·endpoint·연결, 실제 표시 중인 sheet/alert/Files picker, note/PDF 읽기·쓰기·초안, outbox/send, note/block/PDF recovery의 시도와 손상, 미확인 checkpoint, 숨은 conflict choice/local/attempt 자료를 확인한다. 종결 choice와 정확한 owner/주소/recoveryID/backup SHA가 대응하는 보존본은 계속 보관하되 무조건 영구 차단하지 않는다. orphan/손상/미조정 자료는 차단한다.

## 전체 문서 동기화

Workspace의 자동 scene 동기화/역수신은 Document 모드에서 먼저 분기하여 Laplace의 전체 문서 API만 호출한다. 기존 packet/agent revision/단일 scene 조정은 Document 모드에서 거부한다. 페이지 선택으로 legacy checkpoint를 초기화하지 않는다. note·PDF 원문 자체의 기존 API는 출처 참조 편집 경로로 유지한다.

Store의 기존 전체 source envelope 안에 `ccr.document-sync/v1` 상태를 보존한다. 새 상위 원장이 아니다. 전체 Files generation의 typed binding과 operationID를 sending/resolving 이전에 기록한다. API 반환 뒤 전체 document snapshot·요청 UUID·연결 주소/토큰을 확인하고 전체 Files 원본에 저장·재열기한 뒤에만 checkpoint를 synchronized로 바꾼다. 전송/교환 뒤 오류·ACK 유실·409는 held 또는 이전의 durable sending/resolving으로 남는다. 같은 SHA·GET 성공·프로세스 재시작이 자동 해제하지 않는다. 자동 재시도와 후속 자동 발행은 차단한다.

명시 충돌 비교는 실제 `Conflict` DTO와 opaque recoveryID·expected6개를 사용한다. 전체 후보 자료는 Laplace의 검증된 분할 candidate GET으로 읽는다. 기존 sheet arbitration 안에서 현재/기준/외부/제안 원문·페이지 요약·노드 내용을 보여주고, 확인 대화상자 뒤 keepCurrent/useDisplaced만 보낸다. 전체 resolve 재열기와 Files readback 뒤에만 해제한다. 기존/외부/제안 원본 세대는 삭제하지 않는다. ACK 유실의 별도 재확인 버튼은 사용자가 눌렀을 때만 전체 GET과 local Files identity/token/문서/모든 preview를 전후 대조하여 동일 원본일 때 해제한다. 이 경로는 쓰기를 보내지 않으며 미조정 journal의 typed GET 거부나 다른 원본·자산을 조정 성공으로 바꾸지 않는다.

## 검사와 수용 범위

기존 `Tests/checks/canvas-document/run.py --store` 경로가 실제 Store·Model·Document·Files·편집 모듈·DTO를 native 컴파일한다. 기존 runtime/dependency와 같은 isolated context를 사용하며 HOME을 바꾸지 않는다. 출력/모듈/cache/tmp/별도 프로세스의 home은 승인 외장 출력 디렉터리에만 둔다. `store.swift`는 실제 PKDrawing·native Files·UndoManager·새 프로세스 재열기와 URLSession DTO fixture를 검사한다. URLProtocol 자료와 렌더 PNG fixture는 실제 서버 socket/브라우저/사용자 Pencil 인식 성공의 증거가 아니다.

`--sdk-check`는 프로젝트 plist와 실제 전체 CanvasBridge/의존 입력의 iOS27 타입 검사를 수행한다. 본문에 검사 숫자를 기능 동등성 수치로 사용하지 않는다. 정확 실행 소스 SHA·결과·실패/수리 이력은 외장 영수증을 따른다. 독립 Store/UI source 검수·paired 실제 HTTP·설치·실기기/IME/Pencil 최종 수용은 별도이며 전체 제품 완료는 false다.

Pstack architect/how로 기존 소유·mutation·복구 경계를 대조했고 Ponytail로 기존 computed 접근·UndoManager·Files·단일 source envelope·sheet와 DTO를 재사용했다. ARENA·순정 Goal·heartbeat·provider·새 앱/runner/DB는 만들지 않았다. 현재 도구 매핑상 별도 spawn_agent가 없어 이 writer의 자체 검사를 독립 검수로 표시하지 않는다. 부모가 exact source에 독립 검수를 배정한다.

## DOC-STORE-R1 수리

독립 검수의 실제 유실을 수리한다. 기존 구현은 바인딩이 있으면 전체 미저장 문서를 교체될 단일 캐시에만 쓴 뒤 다른 문서를 설치했다. 현재 cache와 새 Store가 다른 문서로 바뀐 뒤 이전 Files에는 편집 전 내용만 남는 P1이었다. a1 검수 WT와 a3 writer WT는 고정하고, 수리는 exact a1에서 분리한 별도 writer에서 수행한다.

다른 ID의 source cache를 쓰는 공통 `writeDocumentSource` 경계는 현재 전체 문서 SHA와 binding.savedSHA, 실제 Files head token, publicationPending 부재 및 전체 문서 재열기 일치를 요구한다. `documentFileReady`라는 UI 상태만으로 보존을 인정하지 않는다. Files 원본 열기는 현재 전체 cache를 먼저 보호하고, 미저장 변경이 있으면 기존 whole Files save/CAS/readback을 수행해 그 결과를 확인한 뒤에만 다른 원본을 설치한다. source가 이미 정확히 저장돼 있으면 새 generation을 만들지 않는다.

바인딩 없음·외부 충돌·읽기 실패·취소에서는 기존 원본과 선택·Undo를 먼저 지우지 않는다. `id=nil`은 현재 문서의 안전 내보내기이므로 별도로 유지하고, 같은 전체 원본을 새 폴더에 연결했을 때 이력을 초기화하는 install을 반복하지 않는다. JSON import와 legacy 복귀도 같은 실제 보존 조건을 확인한다. 기존 Files generation/recovery와 cache 형식을 재사용하며 새 원장/DB/삭제/GC/파일 형식 변경은 없다. native/격리 Files 검사는 GUI·IME·Pencil 인식·기기·설치 수용과 별개다.

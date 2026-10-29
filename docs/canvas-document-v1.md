# 복수 페이지 문서의 첫 구현 단위

기준은 공식 `624597f62326df776099e90a626630e52e751803` / tree `05d2249fbcef40f4c95d02316a75dd0e5f96a9ca`다. 이 문서는 사용자가 수용한 방향을 한국어로 고정한다. 세부 형식명, 버전 숫자와 한도는 사용자 요구를 구현하기 위해 작성자가 선택한 계약이다. 기존 scene API, packet schema, relay wire를 변경하지 않는다.

## 직접 확인된 원앱 근거와 한계

`/Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/myscript-page-management-20261029/observation.json`은 자체 MyScript 노트북의 페이지 복제 1→2와 서재 복귀 후 재열기에서 2페이지 유지를 관측했다. 같은 폴더 `background-observation.json`의 회색 격자/검정 페이지 구분은 시각 관측이며 배경 변경 후 재열기는 미확인이다.

`/Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/myscript-page-data-final-20261029/REPORT.md`와 `result.json`은 notebook object145의 외부 page146→153 순서, 서로 다른 object UUID와 `duplicate_of` 관계를 확인했다. 두 패키지의 내부 pageID는 모두 `qoxhavla`이므로 내부 ID 하나를 전역 페이지 ID로 사용하지 않는다. 외부 UUID와 부모·순서가 식별 근거다. 양쪽 원본 ink SHA는 `9649618db27ab5d22f2f90f7a09baa98dd02f8245c52ff3a3e13453c901dae92`로 같다. 저장 자료의 색상 인코딩, 앱 전체 원자적 snapshot, 배경 재열기, cold restart는 확인하지 않았다. 이 구현에서 원앱 컨테이너를 새로 해독하거나 파일을 가져오지 않았다.

## 새 외곽과 페이지

`CanvasDocument`는 `format=ccr.canvas-document`, `version=1`, 문서 UUID, 문서 revision, 현재 페이지 UUID와 순서 있는 `[CanvasScene]`만 저장한다. 외곽에 구 scene의 `schemaVersion`, 잉크, 노드, 링크를 겹쳐 넣지 않는다. 구 reader가 선택된 페이지만 읽고 숨은 페이지를 버리는 성공 경로를 만들지 않는다. 새 문서 decode 실패는 legacy로 fallback하지 않는다. 알 수 없는 외곽/scene 필드, 새 버전·종류, 빠진 현재 페이지, 중복 페이지 ID, 잘못된 참조는 전체 문서를 거부한다.

구 scene 1/2/3은 읽기 시 명시적으로 한 페이지 문서로 감싼다. 원래 scene ID는 첫 페이지 ID이며 문서 ID로도 유지한다. 새 문서에 대한 기존 단일 scene 저장·게시 호출은 연결하지 않는다. Files의 `workspaceDocuments` 목록은 서로 다른 문서 목록이며 문서 안의 페이지 목록과 같지 않다.

복제는 원래 페이지 바로 뒤에 넣고 새 페이지 UUID와 모든 노드·링크·주석 UUID를 만든다. 링크 양끝과 주석의 노드 참조는 새 노드 ID로 재매핑한다. 원본 페이지, 원시 PKDrawing 바이트, 페이지 범위의 native strokeID와 `sourceStrokeIds`, 외부 Obsidian 경로·blockID·SHA, UTF8 본문·주석·스타일·frame·rotation은 보존한다. 반환되는 ID 대응표는 호출자가 복제 선택을 이어가는 데 쓸 수 있다. 원앱의 내부 pageID나 child_index 숫자를 CCR ID/정렬 규칙으로 복제하지 않는다.

문서 revision은 페이지 복제·교체·전환 때 증가한다. 페이지 전환 epoch는 실행 중에 따로 증가하며 A→B→A에서 예전 snapshot을 거부한다. snapshot에는 문서 UUID·전체 문서 SHA·페이지 UUID·페이지 revision·epoch와 메모리 인스턴스 식별자를 담는다. 새로 연 인스턴스에 예전 callback을 적용하지 않는다. 프로세스를 넘는 비동기 작업의 재개/승인은 이 첫 단위에서 제공하지 않는다.

## 전체 문서 Files 세대

새 head는 `ccr.sill-document-files/v2`이며 기존 `ccr.sill-files/v1` reader가 명시 거부한다. 같은 `<문서UUID>.sill` 안의 새 immutable generation에 `document.json`과 모든 페이지의 `drawing.pkdrawing`·`preview.png`를 쓴다. head에는 문서 SHA, generation UUID, 순서 있는 페이지 ID와 각 자산 SHA를 저장한다.

저장 입력의 모든 페이지·순서·자산을 검사하고, 기존 head token SHA와 비교하며, 기존 세대 전체도 다시 읽는다. 새 세대 전체를 쓴 뒤 실제 파일 readback과 SHA·순서 검증을 완료하고 head를 마지막에 원자 교환한다. 비선택 페이지 변경도 전체 head token의 CAS 충돌이다. 일부 페이지/자산 누락·손상은 전체 읽기 실패이며 선택 페이지만으로 성공하지 않는다. 새 generation 실패 시 기존 head를 유지하고 이전 세대를 삭제하지 않는다. 보안 범위 폴더와 파일 조정을 재사용하며 디렉터리 fd, UUID 경로, no-follow, regular-file 검사로 심볼릭 링크를 따르지 않는다.

협력 writer는 문서별 파일 lock을 쓴다. **비협력 외부 writer에 대한 절대 CAS는 아니다.** 마지막 SHA 확인과 head 교환 사이에 외부 교환이 끼어들면 교환 후 displaced head를 비교한다. 이때 활성 head가 우리 제안일 수 있다. 이전 head·외부 displaced head·제안 generation을 모두 보존하고 `publicationUnconfirmed`를 반환한다. 자동 rollback이나 성공 checkpoint로 바꾸지 않는다. 발행 전 durable `publish-UUID.json`은 재열기에서도 `publicationPending`으로 읽히며 후속 쓰기를 막는다. 정상 전체 readback 후에만 `commit-UUID.json`으로 바꾼다. 이 첫 단위에는 미확인 발행을 명시 조정하는 제품 UI가 없으며 복구 원장을 자동 삭제하지 않는다.

문서 JSON 16MiB, 페이지 128개, 기존 페이지 JSON/잉크 4MiB, 문서 전체 preview 합계 32MiB는 작성자가 선택한 제한이다. 원앱 기능 한도가 아니다. 실제 Files provider의 원격 내구성·클라우드 원자성은 별도 검증 대상이다.

## 이번에 연결하지 않은 제품 경계

Store, Workspace, 기존 CanvasFileWorkspace·Model, relay, Pele, PDF·태그 제품 코드는 바꾸지 않는다. pbxproj는 새 두 소스의 컴파일 등록만 한다. **새 문서 쓰기 제품 UI 활성화는 0이다.** 기존 scene API나 같은 canonical 원본으로 선택 페이지만 게시하는 경로를 추가하지 않는다.

다음 통합은 전체 문서 지원을 명시하는 paired relay capability, 문서 전체 canonical Obsidian/Files CAS·복구, 페이지별 AI 읽기/수정, 전체 페이지 투영, Store/UI를 함께 연결해야 한다. 해당 capability를 확인하기 전에는 새 문서를 같은 원본의 단일 scene으로 게시하면 안 된다. 라이브러리에 현재 페이지를 읽는 속성이 있다는 사실이 게시 허가가 아니다.

페이지 전환/문서 교체의 실제 Store gate는 열린 ink glyph·spacing·shape·math 제안, 카드/노트 편집, PDF pending/held, outbox, block/note/PDF 복구 원장, conflict choice/local/attempt, 미확인 Files 발행 등 **화면에 숨은 복구 상태까지** 조회해 막아야 한다. 이 첫 단위는 앱의 숨은 복구 원장을 직접 읽거나 그 barrier가 통합됐다고 주장하지 않는다. 자체 Files 발행 원장의 지속 barrier와 페이지 snapshot epoch만 구현했다. 원문/draft/작업 ID, Undo, 취소·늦은 callback의 Store 접합은 부모 통합 전 미완료다.

## 검증과 판정

`Tests/checks/canvas-document/run.py --output <승인 외장 경로> --sdk-check`가 실제 macOS PencilKit/로컬 Files 검사와 iOS27의 새 문서 단위 타입 검사를 수행한다. 결과·컴파일 캐시·격리 home·tmp는 출력 경로 안에만 둔다. tracked 결과를 덮지 않으며 HOME을 바꾸지 않는다.

무주입 검사는 PKDrawing 바이트/필압/transform 왕복, ID 재매핑, 구형 reader 거부, 구 scene/Files 읽기, 두 페이지 파일 왕복, 비선택 페이지 CAS, 실제 파일 누락과 권한 실패, ABA 거부다. 별도 주입 검사는 generation 뒤 실패, 교환 뒤 실패, CAS 확인 직후 비협력 외부 head 교환이다. 주입 검사를 OS crash나 원앱 성공 근거로 세지 않는다. 원본 사용자 파일·앱 UI·기기·Host·네트워크·서비스는 사용하지 않는다. 전체 빌드·설치·실기기·MyScript 전체 동등성·제품 복수 페이지 수용은 모두 미완료다.

Pstack의 기존 설계 재사용→경계 구현→네이티브 검증→정확 소스 고정 경로를 적용했다. Ponytail은 기존 CanvasScene, Foundation 파일 조정, PencilKit, Darwin 원자 rename을 재사용하는 데 적용했다. 별도 DB·provider·프레임워크·ARENA·순정 Goal을 추가하지 않는다. 독립 아키텍처 검토 조건은 구현/검사의 기준이며, 이번 코드의 독립 소스 검수와 공식 통합은 별도 단계다.

## 0fd 독립 검수 반례의 수리

`canvas-document-independent-review-0fd008a/REVIEW.md`의 DOC-R1(P1), DOC-R2·R3(P2)는 첫 버전의 실제 실패 근거다. 기존 39조건 통과가 이 실패를 닫았다고 보지 않는다. 원래 영수증과 원본 입력은 보존하며 다음 소스의 좁은 반례 결과를 별도로 연결한다. 독립 재검수 완료 전 SOURCE_CLEAR·paired/UI 수용으로 올리지 않는다.

### 정본 문서 경로와 발행 원장

첫 버전은 선택 폴더 inode만 검사해 문서 디렉터리를 옮기고 같은 이름에 외부 디렉터리를 놓으면 옛 fd 안의 저장을 성공으로 반환할 수 있었다. 이제 root의 UUID 문서 경로와 열린 문서 fd의 dev/inode를 비교하고, generation·pages·각 페이지 디렉터리와 파일 entry도 no-follow identity에 결속한다. 성공/commit 전후에는 정본 문서 경로를 새로 열어 동일 head와 전체 문서·자산을 재검증한다.

선택 폴더 바로 아래 `document-pending-<문서UUID>.json`을 fsync해 문서 디렉터리와 독립된 발행 barrier로 둔다. `document-recovery-<문서UUID>/<시도UUID>/`에는 원래 base와 proposal의 완전한 세대·원시 head를 검증해 보존한다. 경로 교체/교환 후 실패에서는 현재 외부 세대와 displaced 자료도 별도로 보존한다. 알려지지 않거나 손상된 외부 head는 원시 관측 바이트를 보존하고 그 원본 디렉터리를 자동 rollback/삭제하지 않는다. 읽을 수 없는 외부 전체 내용을 안전하게 복제했다고 주장하지 않는다.

새 인스턴스의 load/save는 폴더 수준 barrier를 확인한다. 교체된 옛 문서 디렉터리를 선택 폴더 밖으로 이동해도 새 정본을 `publicationPending`으로 읽으며 후속 쓰기를 막는다. 정본이 없거나 읽을 수 없는데 barrier가 남으면 `pending`으로 거부한다. 정상 전체 readback을 마친 경우에만 바깥 intent를 해당 시도 폴더의 commit 기록으로 옮긴다. 단순 lock 경합을 이 영구 barrier로 바꾸지 않는다.

복구 세대는 크기 제한 안의 실제 파일 사본이다. 이 첫 단위는 성공/실패 자료를 자동 삭제하지 않으므로 기존 immutable generation 외에 보존 공간을 더 사용한다. 활성화 전 기존 generation/복구 보존 정책과 함께 확인할 대상이며, 숨은 자동 정리나 새 DB를 추가하지 않았다. 비협력 writer가 마지막 관측 뒤 다시 경로·내용을 바꾸거나 전체 선택 폴더를 삭제하는 것까지 막는 절대 CAS/클라우드 내구성을 주장하지 않는다.

### byte ingress의 nested 지원 경계

새 Document의 SceneReader와 legacy 바이트 읽기가 같은 엄격한 shape 검사를 통과한 후에만 기존 CanvasScene decoder를 사용한다. scene 1/2/3의 종류·스타일·값 검증은 기존 계약을 재사용한다. 지원 필드는 다음 구조까지 닫힌 목록으로 확인한다.

|구조|지원 키|
|---|---|
|node|id, kind, frame, text, confidence, sourceStrokeIds, vaultNote, isCollapsed, rotationDegrees|
|frame|x, y, width, height|
|vaultNote|path, sha256, relayAddress, cacheTruncated, blockID, sourceState, observedSha256, quoteSha256|
|link / anchor|id, from, to, label, kind, fromAnchor, toAnchor / side, offset|
|annotation|id, nodeId, text, author|
|stroke / InkPoint|id, points, createdAt, visibility, style / x, y, pressure|
|visibility / segment|kind, visibleSegments / lowerBound, upperBound, worldPoints|
|style / color|version, inkType, color, transform, samples / red, green, blue, alpha|
|transform / sample|a, b, c, d, tx, ty / width, height, opacity|
|penSettings|version, color, width|

Files head와 page asset metadata도 알려진 키만 읽는다. 지원하지 않는 키는 선택되지 않은 페이지에 있어도 **decode/저장 전에 문서 전체를 거부**한다. 기존 일반 CanvasScene decoder 전체를 바꾼 것이 아니다. 다른 코드가 unknown 필드를 이미 버리고 typed CanvasScene만 전달했다면 그 유실을 사후 복원할 수 없으므로, 새 문서 raw ingress는 이 경계를 반드시 사용해야 한다. free-author 주석의 author/text 값은 그대로 보존하며 태그 의미를 소급 부여하지 않는다.

### lock 경합

`flock(LOCK_EX | LOCK_NB)`를 사용하고 EWOULDBLOCK/EAGAIN은 한글 `busy` 보류로 반환한다. 이때 head·전체 문서·발행 원장을 변경하지 않는다. 실제 lock holder가 여전히 보유한 동안 MainActor 호출이 반환하고, 명시 해제 후 같은 기대 token으로 정상 저장되는지 검사한다. 이는 추가 flock 대기를 제거한 것이며 동기 NSFileCoordinator와 모든 파일 IO가 비동기로 바뀌었다는 주장이 아니다.

### 재현 범위

`run.py --repairs <독립 검수 폴더> --sdk-check --output <승인 외장 경로>`는 reviewer의 `unsupported-nodes/links/annotations.json` 세 원문 바이트를 그대로 입력하고 SHA를 과거 관측과 대조한다. 디렉터리 rename/copy 후 교환의 원래 반례와 교환 전·generation 후의 동일 경계를 검사한다. 별도 자체 프로세스의 실제 파일 lock을 사용하며 holder의 유한 수명·정상 종료·PID 부재를 기록한다. 기존 39조건·문서 단위 SDK와 좁은 수리 검사를 구분하며 GUI/기기/Pencil 수용으로 세지 않는다.

## Files 저장 재사용 단위 — 782 이후 별도 writer

이 단위는 exact `782978d7bc574080ae72fd9ebd48b5699473f0ea`에서 분리한 `codex/ipad-document-storage-reuse-20261029`의 변경이다. 원래 782 WT는 수정하지 않는다. Store/Workspace/Model·Document JSON·서버·앱 UI와 설치는 변경하지 않는다. 아래 로컬 metadata 형식은 작성자가 정한 것으로 paired 서버 DTO를 대신하지 않는다.

### 전체 내용 불변 저장

기존 root/local pending, 비차단 lock, expected head token, 원래 문서의 모든 페이지·잉크·preview와 정본 디렉터리 identity를 확인한다. 문서 전체 canonical bytes와 모든 preview bytes가 같고 legacy가 아닌 경우에만 새 generation/intent/복구 사본 작성 전에 정본 경로에서 전체 readback을 다시 하고 기존 snapshot/token을 반환한다. native drawing은 Document 바이트와 각 실제 파일의 SHA·바이트 검증에 포함된다. 틀린 expected token, pending marker, 잘못된 자산, 같은 내용의 디렉터리 교체는 통과하지 않는다. legacy v1에서 새 문서 형식으로 올리는 저장과 preview/비선택 페이지/현재 페이지 변경은 생략하지 않는다.

### durable base 참조

신규 로컬 발행 기록은 `ccr.document-publication/v2`이고 `attempt.json`을 해당 root recovery attempt에 독립적으로 fsync한다. root/local intent와 committed/aborted 기록의 기존 수명·보류 조건은 유지한다. v2는 optional `baseReference`를 가진다. `ccr.document-base-reference/v1`의 필드는 `schema`, `documentID`, `generationID`, `headSHA`다. 임의 상대/절대 경로·URL은 받지 않는다.

참조 위치는 선택 폴더 아래 `document-recovery-<documentID>/<generationID>/proposal/`로만 계산한다. target attempt의 `committed.json`은 지원하는 v1/v2 발행 기록이어야 하고 owner 문서·attempt UUID·proposal head SHA가 참조와 일치해야 한다. target current/observed head가 바이트로 같고 그 head SHA가 일치해야 한다. head의 document SHA와 순서 있는 페이지·drawing/preview SHA 전체를 snapshot으로 읽고, fd와 parent entry identity·head/committed 바이트를 재확인한다. head SHA가 모든 자산 manifest를 결속하므로 별도의 자산 목록 사본을 ref에 중복 저장하지 않는다. 미지원 키/버전·owner/UUID·SHA 불일치는 거부한다.

이 검증이 성공하면 새 정상 attempt에 `base/revisions/...` 전체 세대를 다시 쓰지 않는다. 이전 안정 proposal은 그 자리에 그대로 유지하며 head 교환 전과 최종 canonical 검증 단계에서도 참조를 재검증한다. 새 canonical 세대와 새 proposal 독립 사본은 둘 다 유지한다. 기존 782의 v1 committed proposal도 전체 검증 후 재사용할 수 있다. legacy 또는 안정 attempt 위치가 없는 외부 generation은 기존 전체 base 사본으로 보존한다. 위치는 있는데 committed가 없는 미확인 상태나 손상본은 새 generation 작성 전에 보류/거부하며 덮어써 수리하지 않는다.

교환 후 참조 경합이 생기면 저장 성공을 반환하지 않는다. root pending을 유지하고 가능한 원래 base를 열린 원본 generation에서 새 독립 base 사본으로 보존한다. 따라서 **정상 복사만 생략**하며 미확인·외부 세대의 기존 보존은 줄이지 않는다. 원본이나 stable target이 읽을 수 없게 된 경우 복구 성공을 추정하지 않는다.

`recoveryBase(documentID,attemptID:)`는 새 typed attempt의 참조 또는 독립 fallback base를 완전히 검증해서 읽는 비교용 API다. state 설치·선택·원장 해제·자동 저장은 하지 않는다. 문서 root가 pending이면 반환 Snapshot에도 pending을 유지한다. 반환된 base head token을 현재 canonical 저장 승인 token으로 바꾸지 않는다. 예전 v1 독립 archive 자체의 새 UI 조정은 이 단위가 아니며 기존 자료를 변환/삭제하지 않는다.

### 측정과 남은 한계

검사는 같은 자체 입력과 저장 workload를 exact782 Files 소스 및 새 Files 소스로 각각 컴파일해 실제 regular file 내용 바이트와 전체 경로 수를 비교한다. baseline 모드는 세 저장 호출과 측정만 수행하고, 비교 assertion은 새 runner/후속 실행에서 한다. 실제 APFS 물리 할당·File Provider 전송량의 절감이나 사용자 파일 증가율을 주장하지 않는다.

기존 구조가 새 generation마다 자산을 두 벌 유지하는 점과 committed·Undo·복구 참조 누적은 남는다. 참조 재사용은 GC나 전체 보존 용량 상한이 아니다. stable base가 어떤 후속 attempt에서 참조되면 그 수명은 유지해야 한다. 원본·미확인·Undo·외부·기존 recovery 삭제, hardlink/symlink, 새 DB·GC·cleanup은 0이다. 이후 중복 정리도 전체 해시·복원·참조 검증을 통과해야 한다.

독립 검수 후 부모가 공식 통합을 소유한다. Store 자동 저장 활성화는 별도 gate다. 내부 scene mutation/완성 transaction과 외부 full validation의 책임 분리는 다음 Store 단위에서 대조하며, 검증형 computed setter나 shadow activeScene으로 이 단위를 우회하지 않는다.

이 자체 두 페이지 표본의 정확 비교 결과는 다음과 같다. 기존 실행물을 읽은 추산이 아니라 동일 입력·저장 workload를 exact782와 변경 소스로 각각 실행한 결과다.

|한 호출의 추가량|782|재사용 소스|
|---|---:|---:|
|불변 no-op의 논리 내용 바이트|15,121|0|
|불변 no-op의 새 전체 경로|40|0|
|정상 변경 저장의 논리 내용 바이트|15,161|11,356|
|정상 변경 저장의 새 regular file|23|17|
|정상 변경 저장의 새 전체 경로(디렉터리 포함)|40|28|

정상 변경에서는 base payload 전체 재복사와 그 두 head 사본이 없어지고 typed reference/attempt metadata가 추가됐다. 새 canonical 및 proposal 자산 두 벌은 유지한다. 이 작은 fixture의 숫자는 사용자 파일 증가율이나 물리 저장공간 절감량으로 외삽하지 않는다. 초기 컴파일의 빠진 try 두 곳과 기존 교환 fixture가 새 no-op으로 분기한 실패도 별도 영수증으로 보존했다. 최종 recoveryBase의 pending 표시 보완 후 해당 27개 재사용·복구 조건, DOC-R1/2/3의 77개 assertion과 iOS27 문서 단위 타입 검사를 정확 변경 소스로 다시 확인했다. 먼저 통과한 기존39는 보완 전과의 차이 범위를 영수증에 명시해 구분한다.

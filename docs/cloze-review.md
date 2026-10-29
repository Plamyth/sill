# 같은 Markdown의 빈칸 복습

기준은 공식 `c8992bbec29297148eb5a4b69b072fb3d579cdbf` / tree `b61c8345664b2b2bf96f8b37d6930a7a3ac98588`다. 전용 `cloze-review-20261029/source`, branch `codex/ipad-cloze-review-20261029`에서만 수정한다. 원 담당은 기존 `01a183db-e516-7900-ba5c-5cbd3f7ff7a7`이다. 새 DB·평가 엔진·서비스·API·Anki 이력 복제는 없다.

## 관측과 구현 계약

R111 `margin-anki-export-observed-spec.md`는 Mac MarginNote 4.4.6의 자체 APKG에 실제 `{{c1::Core}}` 질문과 앞/뒤·원문 링크·별도 복습 일정이 저장됐음을 기록한다. 실제 Anki 가져오기·모든 Cloze 규칙·원앱 iPad·Pencil 동등성의 근거가 아니다. CCR의 아래 동작은 이 좁은 표현을 기존 복습 카드에 연결한 명시 계약이다.

- 질문의 실제 선택 글자 전체를 ‘선택 글자를 빈칸으로’ 명령으로 `{{c1::선택 원문}}`에 감싼다. 같은 질문의 여러 c1은 함께 가린다. 자동 c2 번호나 새 카드·평가 식별자는 만들지 않는다.
- ‘선택 빈칸 해제’는 표식 전체 또는 안의 원문 전체를 선택했을 때만 그 표식을 제거한다. 일부 글자·범위 밖·부분 grapheme·기존 표식 위 중첩 지정은 거부한다.
- 앞면은 `[빈칸]` 표시용 문자열을 만든다. 뒤집으면 기존 back과 별도로 ‘빈칸 원문’을 표시한다. 평문 카드의 기존 앞/뒤 동작은 유지한다. 표시 문자열을 저장 초안에 쓰는 경로는 없다.
- 단일 줄의 비어 있지 않은 c1 원문만 지원한다. 다른 번호·힌트 `::`·중첩 중괄호·손상/고아 표식·이스케이프된 표식·코드/HTML 주석과 섞인 표식은 추측하지 않는다. 미지원 질문도 원문 필드/전체 Markdown에서 보존·수정·저장할 수 있지만 복습·평가는 명시 안내와 함께 거부한다. 자동 정규화·평문 fallback은 없다.

기존 `VaultReviewCard`의 front/back·정본 Markdown 표식·metadata를 그대로 사용한다. 구조 편집은 기존 `replacing(.front,with:)`로만 수행한다. back/본문/원문 참조와 cardID/eventID/ratedAt/dueAt는 바꾸지 않는다. 평가는 기존 5분/10분/24시간/48시간 간격과 동일 Save/GET 및 noteRecovery를 사용한다.

## 선택 소유와 복구

질문/답 필드의 기존 NSRange를 해당 필드의 UTF16 범위로 검증하고, source prefix의 실제 UTF16 길이를 더해 기존 `vaultSelection`에 연결한다. 답 필드로 선택을 옮긴 뒤 질문의 이전 캡처는 사용할 수 없다. 한글·NFD·emoji grapheme의 중간을 선택 범위로 확대해 저장하지 않는다. 잘못된 선택 callback도 기존 선택 세대를 은퇴시켜 이전 동작을 재사용하지 않는다.

기존 `VaultReviewEditSession`을 유지하고, 빈칸 동작을 위한 불변 캡처에 해당 session·필드 NSRange·기존 noteEditGeneration만 묶는다. 새 가변 선택 정본은 없다. 선택 A→B→A, 원문 텍스트 A→B→A, 연결·노트/카드 선택·편집 session 변경·busy·충돌 때 캡처를 거부한다. 실제 조합·Scribble 입력 자체의 기존 보존 경로는 바꾸지 않고 구조 명령만 막는다.

복습 필드 뷰 identity는 기존 inputSessionID로 고정한다. 선택을 포함하는 전체 session을 identity로 쓰면 질문 선택만 바꿔도 필드가 재생성돼 선택이 초기화되므로 이 한 호출 지점을 수리했다. 노트 재열기/편집 session 교체에는 기존 inputSessionID가 바뀌어 같은 방식으로 은퇴한다. 명령 캡처는 여전히 전체 session·선택/편집 세대를 검사한다.

Store는 기존 `vaultDraft`에 표식 원문만 쓰며 같은 noteRecovery에 보존한다. 일반 note CAS/전체 GET·freshStore 복구·평가 원장을 그대로 재사용한다. 미확인 평가나 저장을 자동 재전송하거나 conflict guard를 풀지 않는다. 공유 Store/Workspace의 복습 구간 외 PDF·EPUB·Files·그룹/용지 코드는 수정하지 않는다.

## 검사 경로

`python3 Tests/checks/pdf-view-product/run.py --cloze --output <storage-route 승인 출력>`으로 기존 실제 Store·격리 runtime·ObsidianVault 파일 CAS 실행기의 의존 입력과 stdio helper를 재사용한다. 새 `ClozeChecks.swift`만 main으로 선택하며 기존 전체 복습/385/PDF/EPUB 검사를 무조건 반복하지 않는다. 이 실행은 실제 격리 파일 IO이며 HTTP socket·실제 Anki·GUI 수용을 뜻하지 않는다. UI는 실제 질문 선택 binding/명령과 복습 표시 코드를 대조하고 iOS SDK에서 typecheck한다. Pencil 입력·실물 UI/설치·Host/오디오/키/권한·공유 서비스·사용자 vault 변경은 하지 않는다.

Pstack Feature/how로 기존 데이터·선택·저장/평가 흐름을 먼저 대조했다. 선행 조건은 exact 공식·clean 전용 WT·storage-route다. 네이티브 Store 검사와 SDK 입력 검사는 독립 읽기로 병렬 진행한다. 공유 쓰기는 분리한 WT에만 있고, 정본 Markdown·Store·UI의 단일 기능 결합은 같은 소유자가 담당한다. Ponytail은 기존 parser/field editor/NSRange·선택 세대·Save/GET/recovery 재사용에 적용했다. ARENA·순정 Goal·중첩 worker·루프는 사용하지 않는다. 독립 소스 검수와 공식 반영은 부모 단계이며 writer 검사를 그 판정으로 대체하지 않는다.

검사 helper 보완은 기존 `OwnVault`의 note/save/PDF 응답을 원시 JSON에서 바로 Codable로 읽는 것이다. `JSONSerialization.jsonObject`로 읽은 value를 다시 직렬화하는 옛 경로는 질문 fixture 본문 첫 BOM 3바이트를 잃어 SHA 검증에 거부됐다. 같은 원시 JSON을 직접 JSONDecoder로 읽으면 실제 파일 SHA와 일치함을 별도 재현했다. 실제 제품 API·SHA guard·Relay·권한은 변경하지 않았다. 이전 실패 출력과 진단 입력/출력을 전용 evidence에 보존한다.

최종 고정 입력 네이티브 검사는 본 검사95건·새 프로세스 재열기2회(자식 확인4건), 실제 UI Binding 함수 추출 실행, 실제 Obsidian 파일 CAS·전체 GET·외부 역수신·기존 hard 평가·평가 중복 거부·ACK 미확인·409·freshStore 복구·선택/텍스트/연결 ABA를 통과했다. normal 보호 파일과 실행 전후 소스 SHA는 같고 atomic helper4개가 모두 종료됐다. 실제 SwiftUI/UIKit 손조작이나 Pencil 입력을 수용한 결과는 아니다.

최종 입력 고정 전에 검사 컴파일 도중 main에 UI Binding 검사를 추가한 실행은 무효로 남겼다. 그 실패를 통과로 고치지 않았고 이후 원본 입력을 바꾸지 않는 성공 실행으로 다시 검증했다. 앞선 전체 iOS27 typecheck 뒤 한 줄 UI identity 수리를 적용했다. Workspace 단독 frontend 방식은180초 예산을 넘겨 판정 불가로 보존하고, 기존 Swift driver 명령으로 최종32입력 SDK 결속을 검증한다. 전체 앱 번들 빌드·xrOS·실제HTTP·기기·GUI·설치는 별도 미수행이다. 정확한 종료 코드와 최종 커밋/입력 SHA 결속은 writer 영수증에 둔다.

최종 Swift driver의 iOS27 전체 Canvas typecheck 종료 코드는0이며 입력32파일과 전후 SHA가 일치한다. 별도 UI 소스 연결11조건도 통과했다. 성공 네이티브 실행의 checkpoint 표기는 기준c899이고 소유 dirty 구현의64입력 SHA가 최종 커밋의 같은 파일과 일치함을 따로 대조한다. 과거 실행의 commit 필드를 새 커밋으로 고치지 않는다.

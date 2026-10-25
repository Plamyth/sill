# Obsidian 원문 복습 카드

기존 그림판에서 복습 카드를 추가하면 질문·답 필드를 기본으로 표시한다. 두 필드는 기존 VaultMarkdownEditor의 글자 교정·Scribble·표시 정책을 공유하며, 저장 후 복습 보기에서 뒤집기와 좋음 · 24시간 후를 사용한다. Markdown 원문 편집은 선택 경로로 남는다. 노트 하나에 카드 구역 하나만 지원한다. 빈 질문·답은 복습하거나 평가하지 않는다. 앞뒤 전환은 임시 화면 상태이며 질문·답·기한의 원본은 Markdown 파일이다.

```markdown
<!-- ccr-review-card:v1 {"cardID":"11111111-1111-4111-8111-111111111111","dueAt":null,"eventID":null,"ratedAt":null} -->
<!-- ccr-review-front -->
질문 Markdown
<!-- ccr-review-back -->
답 Markdown
<!-- /ccr-review-card -->
```

첫 줄의 JSON은 키 정렬된 고정 형식이다. `cardID`, `dueAt`, `eventID`, `ratedAt` 네 키를 모두 유지한다. ID는 소문자이며 0이 아닌 정규 UUID이고 평가 이벤트 ID는 카드 ID와 달라야 한다. ID는 인증 서명이나 권한 증명이 아니다. 사람과 AI는 같은 원문의 질문·답을 편집할 수 있다. 메타정보를 편집할 때는 위 형식과 검증 규칙을 지켜야 한다.

평가 전에는 마지막 세 평가 필드가 모두 `null`이다. 평가 후 `ratedAt`과 `dueAt`은 UTC Unix 초 단위 정수이며, `0 ≤ ratedAt ≤ 253402214399`, `dueAt = ratedAt + 86400`을 만족한다. 새 평가는 마지막 평가보다 과거 시각을 허용하지 않는다. 앱은 `injectedDate`의 초 미만을 버리고 ‘좋음 · 24시간 후’라는 자체 고정 간격만 적용한다. 동일 이벤트를 순수 함수에 다시 주면 원문 그대로 반환한다. MarginNote 비공개 SRS·장기 반복 정책·다른 평가 등급·cloze는 구현하지 않았다.

네 표식은 각각 독립된 행에 한 번씩, 위 순서로 있어야 한다. 첫 표식 바로 다음 행은 앞면 표식이다. `ccr-review` 예약 문자열의 중복, 누락, 잘못된 ID, 비정규 JSON, 미지원 버전, 일부 평가 필드만 존재하는 상태, 잘못된 시간·간격은 자동 편집을 거부한다. 코드 펜스·frontmatter·이미 열린 HTML 주석 안의 표식도 거부한다. 거부된 노트는 원문 편집기로 그대로 볼 수 있다. 원문 전체 크기는 기존 1 MiB 한도를 따른다.

틀 삽입은 기존 원문 바이트 뒤에 개행과 빈 틀을 덧붙인다. 기존 문서의 BOM·CRLF·Unicode 정규화·줄바꿈을 재구성하지 않는다. 평가는 머리말 JSON 바이트 범위만 교체한다. 질문·답과 구역 밖 바이트는 보존한다. 질문·답 필드는 parser가 제공한 UTF-8 범위 중 해당 부분만 바꾼다. 표식 직전 개행 한 개는 구조 경계로 분리하고, 필드 안의 수식·HTML·블록 표식·빈 줄·혼합 개행·결합문자는 그대로 저장한다. 빈 질문·답도 저장할 수 있지만 복습을 시작하지 않는다. 예약 표식 중복이나 미완성 코드 펜스 등 기존 parser가 해석할 수 없는 입력도 초안·저널에서 삭제하지 않는다. 이 경우 안내와 함께 원문 편집으로 이어가며, 명시적으로 필드로 돌아갈 때까지 원문 모드를 유지한다. 앱은 원문 편집기, `saveVaultNote`, SHA CAS, 복구 저널, `refreshVaultNotes`를 재사용하며 scene·relay·wire 스키마나 획·provenance에 새 쓰기 경로를 만들지 않는다. 기존 연결 노트의 표시 캐시 갱신 책임도 기존 Store 경로에 남는다.

질문·답 편집 세션은 입력 세션·경로·기준 SHA·카드 ID·텍스트 선택·선택 요소와 선택 세대를 캡처한다. 선택을 바꿨다가 되돌린 경우도 이전 필드 콜백을 거부한다. 조합·Scribble·펜 교정 중에는 입력만 저널에 보존하고 저장·취소·복습 제출을 막는다. 저장 중에는 필드 편집도 거부한다. 취소 · 초안 보존은 기존 저널을 확인한 뒤 입력 세션만 갱신하고 화면을 닫는다. 원격 충돌과 늦은 응답은 기존 복구 계약으로 처리한다. 새 상위 편집 상태·저널·입력기는 만들지 않는다.

HTML 주석 토큰은 행 안에서도 왼쪽부터 읽는다. `<!-- 닫힘 --> <!--` 다음에 있는 카드는 열린 주석 안이므로 해석·복습·평가를 거부하며 저장 호출은 0이다. 닫힌 여러 주석, 원문 바이트, 펜스·frontmatter 조건은 유지한다. 고정 294의 P2 수정이며 독립 검수 CLEAR를 뜻하지 않는다.

복습 세션은 평가 이벤트 UUID, 원본 경로·SHA·바이트, 편집 세션, 편집 세대, 텍스트 선택과 선택 요소를 캡처한다. 평가 전 dirty·marked text·펜 입력 busy·전환·SHA 변경은 거부한다. 평가를 초안에 반영한 뒤 기존 저장 경로를 호출하고, 검증된 저장 응답과 GET 원문이 일치해야 저장 완료를 표시한다. 진행 중 중복 탭과 늦은 콜백은 같은 평가를 새 이벤트로 재발행하지 않는다. 응답 유실·충돌·재조회 실패는 제출한 정확한 원문과 이벤트를 기존 저널에 보존한다. 기존 복구 경로는 재조회로 이미 저장된 같은 원문을 수용하며 새 평가를 만들지 않는다. 이후 입력은 저장 응답으로 덮지 않는다.

## 재현

```sh
python3 -B Tests/checks/obsidian-review-cards/run.py \
  /Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/ipad-review-card-editing-20261026/check-final
```

러너는 storage-route 출력 경로를 확인하고 실제 `CanvasModel.swift`, `CanvasStore.swift`, `CanvasWorkspace.swift`와 검사 입력의 전후 해시를 기록한다. Mini에는 작업 범위의 입력만 `mini-ephemeral-source`로 보내고 삭제 확인 영수증을 회수한다. Mini SDK에는 기존 Store의 `PKStroke.id`·`PKStrokeRecognizer`가 없으므로 순수 모델을 Mini에서 컴파일·실행하고, 전체 실제 Store를 사용하는 좁은 네이티브 검사는 맥북 Xcode SDK로 실행한다. UI 소스는 문법 파싱만 하며 iOS 전체 SDK 타입 검사와 실제 화면 수용은 부모 담당이다. 새 앱 Swift 파일을 만들지 않아 Xcode 소스 목록 변경은 없다.

검사는 실제 Model/Store 소스를 컴파일한다. 격리된 일반 Markdown 파일과 새 Store 인스턴스로 자동 평가 저장·재열기, 외부 원문 편집→refresh, 중복 이벤트, SHA 충돌, 입력·선택·세션 전환, 동시 편집, 잘못된 저장 응답, 재조회 실패, 응답 유실 후 복구를 확인한다. 테스트 suite는 격리 root 아래 `preferences/review-fixture` 절대 경로다. `.plist` 물리 위치와 별도 프로세스의 복원을 확인하고, 추가한 `scope` 키만 공식 API로 정리한 뒤 같은 두 경로에서 부재를 검증한다. 임의 이름 도메인과 `removePersistentDomain`을 사용하지 않는다. 현재 8dc 계열의 `CanvasStore(defaults:)`에 해당 절대 suite를 명시적으로 주입한다. 상태 경로도 별도 홈 아래인지 확인한 뒤 Store를 만든다. HOME만으로 preferences 격리를 주장하지 않는다. 지우개 setter는 호출하지 않는다. 초기 Tesla의 이름 기반 suite 및 테스트 키 정리 이력은 외장 `ipad-obsidian-review-cards-20261026/preferences-correction.json`에 보존되어 있으며 현재 검사와 구분한다.

이 파일 경계 fixture는 실제 Obsidian helper/API·실사용 vault 검증을 대신하지 않는다. 실제 helper를 통한 양방향 파일 왕복, 독립 검수, 전체 iOS SDK, 공식 통합·설치·테스트 반영, 최종 Pencil 입력은 부모가 같은 커밋에서 확인한다. 실기기·UI·호스트·음성·권한·키·설치·기존 서비스·실사용 vault는 이 검사에서 변경하지 않는다.

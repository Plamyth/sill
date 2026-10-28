# Canvas 명시 조정 client 제품 접합

868fa036의 지속 barrier 위에 접합한다. 서버 원소유는 de1f88f9b0de69608732602b0a8acc2ae6ab3af8 / tree0f03b7c72eb5cd540d1471047281f19fc5b9a014다. 정확한 계약은 서버의 CanvasRelay/RECONCILIATION-CONTRACT.md이며, 부모 조율담당이 기존 사용자 승인 목표의 결합 P2를 해결하려고 채택했다. 사용자가 개별 DTO 필드 자체를 직접 확정한 것으로 기록하지 않는다. 서버 코드를 가져오지 않았다.

작은 synthetic 실제 wire 예제만 producer Git 객체에서 읽어 reconciliation-wire-example.json으로 고정했다. SHA와 출처는 reconciliation-provenance.json이다. 다른 worktree의 수명이나 경로 별칭을 검사 실행 조건으로 삼지 않는다. source/output 경로는 분리하며 실행 결과·홈·모듈·tmp는 --output의 storage-route 검증 외장 아래다.

## 실제 제품 진입점

도구 → Obsidian 충돌 자료 비교·명시 조정 → 현재/기준/외부 변경/제안본의 SHA·원문·PNG 미리보기 → 현재 서버 원문 유지 또는 보존된 외부 변경본 선택 → 한글 확인 alert → PUT → canvas와 note GET 재조회 → 선택본 적용이다. 단순 SHA 일치 또는 no-op 확인 버튼으로 대체하지 않았다. invalid/null 후보는 원문 대조만 하고 선택 버튼은 비활성화한다. 원문은 UTF-8/CRLF 바이트 SHA로 검증하며 1MiB, scene4MiB, PNG5MiB, 응답64MiB 한도를 대조한다. ImageIO thumbnail은 최대1024px이고 서버 PNG dimension8192 상한도 확인한다.

PUT은 recoveryID/expected/decision 세 필드만 쓴다. expected의 다섯 SHA는 null을 포함해 그대로 보낸다. 원문 text/path를 쓰기 요청으로 조립하지 않는다. 선택본의 metadata·scene/native projection·PNG·원문 SHA를 검사하고 성공 ID/decision/resolved/metadata와 재조회 canvas·note 바이트까지 맞아야 적용한다. unknown 버전/kind, 잘못된 ID/geometry/native/PNG, stale/invalid 후보·읽기 불일치는 차단 상태를 유지한다.

게시 전에 iPad scene/native 원본을 CanvasConflictLocal-무작위UUID.json에 쓰고 재읽기 SHA를 확인한다. CanvasConflictChoice.json은 token 없이 원래 snapshot·expected·선택·로컬 SHA·복구 파일명만 보존한다. 결과 미확인 상태의 재열기는 같은 선택 결과 확인만 허용한다. 정상 응답 유실 후 같은 ID/decision/expected의 명시적 확인은 가능하지만 자동 재시도는 없다. 실패한 요청·원본 복구본을 삭제하지 않는다.

typed409는 이전 선택을 refreshRequired로 보존한다. 조정 중 외부 변경으로 최신 recoveryID가 생겼으면 ‘이전 요청을 보존하고 새 자료 다시 읽기’가 같은 scene ID의 GET으로 새 expected/materials/history를 가져온다. 이전 요청은 별도 local attempt에 보존한다. GET이나 보존 IO가 실패하면 이전 요청을 잃지 않는다. 새 자료 읽기는 새 선택 PUT을 보내지 않는다. history는 recoveryID와 파일 SHA/null만 읽고 자동 선택 근거로 쓰지 않는다.

조회 후 scene/주소/token/로컬 SHA가 달라지거나 Pencil·수식 입력·수식 제안·댓글 입력/초안·텍스트 제안·note/block 편집·Files 저장이 진행 중이면 선택 적용을 거부한다. canApplyReconciledCanvas는 이 조정 경로의 준비 조건이며 기존 공유 inkBusy/Undo/selection 함수를 바꾸지 않는다. Store는 기존 importScene과 persistScene을 재사용한다. cache IO는 메모리 교체 전에 수행하고 이전 로컬 원본은 별도 파일로 유지한다. Files 원본은 기존 generation/CAS 저장 경로와 상태를 유지하며 cache 반영만으로 Files 저장 성공을 표시하지 않는다. 서버 조정 자체의 Undo를 구현했다고 주장하지 않는다.

서버에 보존된 JSON은 키 순서·들여쓰기까지 원본 SHA를 유지한다. iPad가 decode/encode한 canonical SHA는 checkpoint의 optional localSceneSha로 별도 보관한다. 일반 자동 저장이 의미 없는 JSON 재정렬을 새 편집으로 판단하지 않는다. 일반 ACK 읽기 복구에서도 이 기준을 갱신하며 새 편집 때는 기존 note SHA를 base로 사용한다. scene/packet schema는 이 필드로 바꾸지 않는다. Model 상단의 runtime/actualCodeImages와 Scripts는 이 단위에서 수정하지 않는다.

## 검증과 남은 수용

`python3 Tests/checks/ink-glyph-edit/reconciliation-check.py --output <검증된 외장>`은 실제 DTO/CanvasRelay/CanvasStore/PKDrawing/ImageIO·파일 API와 실제 Workspace async 함수 본문을 컴파일해 실행한다. UI 상태 보관은 harness이며 transport는 URLProtocol fixture다. 두 결정, 정확한 PUT/null, 잘못된 자료·SHA·응답·재조회, ACK 유실, 재열기, stale 입력, 현재 초안, 최신 child ID 재조회, canonical baseline과 불필요한 자동 저장 거부를 확인한다. 실제 server 파일 교환은 producer의 별도 영수증이며 이 client 시험에서 재실행한 것으로 세지 않는다.

SDK/정상 unsigned 번들 검사는 별도 영수증이다. 실제 iPad 버튼·시각·터치·native 인식·HTTP socket 짝·signed artifact·설치·readback 수용은 false다. unsigned build4와 debug loader를 설치 후보로 세지 않는다. 실제 code image는 Sill.debug.dylib도 별도 기록한다. Ohm의 runtimeReceipt/validator 후속이나 Sartre spacing은 가져오거나 수정하지 않는다. 공식 통합과 exact paired HTTP 및 독립 검수는 부모 소유다.

Pstack으로 기존 호출/저장 실패 경계를 따라 반례를 확인하고 Ponytail로 기존 menu/import/복구/플랫폼 기능을 재사용했다. 새 provider·모델·Host·앱 설치·Pencil 요청·ARENA·순정 Goal은 없다. 전체 MyScript/MarginNote 완료는 false다.

# 저장 보존 충돌의 client 소비

Laplace의 relay43f840e/b111 결합 반례에서는 실제 교환 후409인데 활성 note는 제안본B이고 외부C는 보존 inode에 있었다. 기존 두 async 함수가 pending/local SHA 일치로 B를 checkpoint에 승인한 뒤 D를 자동 저장했다. 원본 반례는 외장 relay-rereview-43f840e/REVIEW.md와 client-scenario.json에 보존한다. 새 client는 문구·경로 substring으로 오류 의미를 추정하지 않는다.

CanvasRelay.response는 혼합형 JSON을 읽고 HTTP 상태와 구조화 필드를 함께 보존한다. `code: note_reconciliation_required` 또는 `reconciliationRequired: true`는 명시 조정 필요, `reconciliationRequired: false`와 `publicationAttempted: false`는 게시 전 거부로 분리한다. 필드 없는409는 의미 미확인이며 원격이 그대로라고 추정하지 않는다. 외부 복구 경로를 화면에 노출하지 않는다. scene schema3와 packet schema1은 변경하지 않았다. 로컬 checkpoint/노트·문단 복구 레코드의 optional saveConflict만 확장했다.

CanvasWorkspace의 미조정/미분류409는 기존 checkpoint에 saveConflict와 pending/base를 유지한다. 반복 GET, 새 입력, 재열기 및 프로세스 재시작의 초기화에서 SHA만으로 해제하지 않는다. 이미 blocked이면 같은 checkpoint를 주기적으로 다시 쓰지도 않는다. 일반 통신 ACK 유실은 acknowledgementLost로 구별하고, GET에 미조정 marker가 없을 때 기존 읽기 복구를 유지한다. 서버가 미조정 marker를 반환하면 SHA를 비교하기 전에 blocked를 보존한다. 서버 상태와 주소·토큰·scene가 바뀐 늦은 읽기도 수용하지 않는다.

기존 도구 메뉴와 원문 편집기를 통해 읽고, 한글 확인 alert에서만 기준 조정을 실행한다. 이 작업은 새 PUT/rollback을 보내지 않는다. 로컬/remote bytes SHA와 문서 SHA, scene/연결/입력 재확인 후, 서버 GET의 `reconciliationRequired == false`까지 확인해야 한다. marker true 또는 필드 부재, 새 로컬 편집이면 조정하지 않는다. 보존 journal 자체를 client가 임의 삭제하거나 해제하지 않는다. 노트·문단 입력은 기존 복구 UI/명시적 버리기 경계를 유지하며 미조정 복구 레코드를 자동 재제출·삭제하지 않는다.

Store는 게시 전에 unclassified 표식을 복구 레코드에 먼저 저장한다. 뒤늦은409의 구체 표식 저장이 IO로 실패해도 앞의 미확인 표식이 남는다. 충돌 후 새 타이핑으로 복구 레코드를 다시 작성해도 표식을 유지한다. 응답 확인 없는 성공 문구·dirty 삭제는 없다. 일반 성공에서만 게시 전 임시 표식을 정리한다.

## 부모를 통한 paired relay 계약 요청 — 아직 relay 반영 수용 아님

- 보존 충돌409는 `code: note_reconciliation_required`, `reconciliationRequired: true`, 필요하면 `publicationAttempted`를 구조화해 반환한다. 원래 raw문구/경로는 client 분기 입력이 아니다.
- 같은 note의 GET은 원문과 함께 durable `reconciliationRequired`를 반환한다. 미조정 journal이 남은 동안 새 client의 새 PUT도 같은 코드로 거부한다. 새 ObsidianVault/서버 프로세스 재시작에도 유지한다.
- 게시 전 거부는 `publicationAttempted: false`, `reconciliationRequired: false`로 구분한다. GET의 false는 해당 note/journal의 실제 조정 완료를 뜻해야 한다. 명시 조정과 journal 해제는 relay 원담당 계약으로 확정해야 하며, client의 SHA 일치나 alert만으로 journal을 해제하지 않는다.
- relay43f840e에는 이 metadata/서버 쓰기 차단 계약이 아직 없다. 따라서 legacy409는 안전하게 보존하지만 자동 정상 복귀를 주장하지 않는다. 새 paired exact HTTP·재시작·서버 새 쓰기 거부·명시 조정 후 복귀 검사가 남는다. relay 소스·서비스·사용자 vault는 변경하지 않았다.

재현: `python3 Tests/checks/ink-glyph-edit/vault-conflict-check.py --output <storage-route 검증 외장 출력>`.
실제 CanvasRelay/Store/PKDrawing 파일 API를 컴파일하고 URLProtocol의 구조화/legacy409 및 복구 파일 왕복을 실행한다. Workspace의 세 async 함수와 checkpoint/오류 선언은 원본에서 수정 없이 추출한다. 그 harness의 transport·renderer·Store·파일 래퍼는 fixture다. 기존 실제 교환 반례의 A/B/D JSON과 SHA를 재사용하며 실제 relay 교환을 다시 실행한 근거나 URLSession HTTP·SwiftUI·Pencil 수용으로 확대하지 않는다. 일반 ACK 유실 회복을 대조군으로 유지한다.

Pstack의 호출 경로/실패 경계 대조와 반례 검증, Ponytail의 기존 복구·선택 UI 재사용을 적용했다. 새 관리 계층·provider·의존성·ARENA·순정 Goal은 없다. 부모의 exact 후보 독립 검수와 새 relay 계약 수렴은 별도이며 전체 앱 완료는 false다.

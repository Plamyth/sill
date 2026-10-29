# 문서 전체 릴레이 v1 계약

이 문서는 클라이언트 SDK와 Store를 병렬로 구현하기 위한 고정 인터페이스다. 서버의 독립 검수, Swift URLSession 결합, 설치 및 실기기 수용은 별도 단계다.

서버 구현은 공식 `9006908998dbcbe0b278b3dc75c71d5d2006342a`에서 시작했다. 이후 공식 `0c230d2ad0e360dcf7ee0ef31a849fc3832ef1a5` / tree `ebe9215b7499a9cd8b7401807d9efcdb3e5852eb`에 PDF·태그가 결합됐고, 현재 접합 검수 기준은 모델 782를 포함한 공식 `b1b7e30efb32a615eae847cbf8280983fb3b0982` / tree `e7ce8079e3ea3753814be615a78ade2f6914d71b`다. 원래 작업 WT와 다른 담당의 변경을 보존한다.

형식명·DTO·한도 계산은 부모 조율 담당이 수용한 설계의 구현 선택이다. 사용자가 각 세부값을 직접 확정한 것으로 기록하지 않는다. iOS/Core 및 기존 packet 계약은 이 서버 단위에서 변경하지 않는다.

## 인증과 capability

모든 요청은 기존 `X-Canvas-Token` 인증을 사용한다. PUT의 Content-Type은 `application/json`이다. 새 인증이나 Host 프로토콜은 없다.

기존 `GET /vault/canvas/capabilities`의 200 응답은 다음과 같다. 클라이언트는 바깥 객체의 향후 추가 필드를 허용하되 사용하는 문서 capability의 형식·버전·필수 기능·한도를 확인한다.

```json
{
  "schema": "ccr.canvas-capabilities/v1",
  "sceneSchemaVersions": [1, 2, 3],
  "nodeKinds": ["note", "box", "ellipse", "line"],
  "diagramProjection": "ccr.diagram-shapes/v1",
  "document": {
    "schema": "ccr.vault-document/v1",
    "format": "ccr.canvas-document",
    "versions": [1],
    "wholeDocument": true,
    "explicitConflictResolution": true,
    "maxDocumentJSONBytes": 16777216,
    "maxPageCount": 128,
    "maxPreviewTotalBytes": 33554432,
    "maxRequestBytes": 67139536
  }
}
```

capability 부재, 404·401, 해석 실패 또는 미지원 값이면 문서 쓰기를 시작하지 않는다. 문서 전체를 로컬 미동기화 상태로 보존한다. 선택 페이지를 기존 scene API로 보내거나 같은 UUID의 단일 scene으로 덮는 fallback은 금지한다. 기존 독립 scene 지원과 문서 지원은 별개다.

## 문서 요청과 성공 응답의 정확 타입

아래 표기는 JSON 필드와 필수·선택 여부를 표현하며 Swift 타입 이름을 강제하지 않는다. `SHA256`은 소문자 16진수 64자리, `Base64`는 원본 바이트의 정규 base64다. 요청 URL과 자산 ID에는 소문자 UUID를 사용한다. 원본 JSON 내부의 UUID 철자와 원문은 재작성하지 않는다. revision은 0 이상의 안전한 정수다.

```ts
type UUIDString = string;
type SHA256 = string;
type Base64 = string;
type DocumentBase = {
  noteSha256: SHA256;
  documentSha256: SHA256;
  manifestSha256: SHA256;
};
type DocumentPageMetadata = {
  id: UUIDString;
  drawingSha256: SHA256;
  previewSha256: SHA256;
};
type DocumentPageWire = DocumentPageMetadata & {
  previewPNGBase64: Base64;
};
type PutDocumentRequest = {
  base: DocumentBase | null;
  documentJSONBase64: Base64;
  documentSha256: SHA256;
  pages: DocumentPageWire[];
};
type DocumentSummary = {
  schema: "ccr.vault-document/v1";
  id: UUIDString;
  path: string;
  revision: number;
  activePageID: UUIDString;
  noteSha256: SHA256;
  documentSha256: SHA256;
  manifestSha256: SHA256;
  generation: UUIDString;
  pages: DocumentPageMetadata[];
};
type DocumentBundle = Omit<DocumentSummary, "pages"> & {
  documentJSONBase64: Base64;
  pages: DocumentPageWire[];
};
```

| 요청 | 성공 상태 | 응답 타입 |
| --- | --- | --- |
| `GET /vault/document?id=<documentUUID>` | 200 | `DocumentBundle` |
| `PUT /vault/document?id=<documentUUID>` | 200 | `DocumentSummary` |

GET/PUT의 query는 `id` 하나만 받는다. 중복 query, 호출자가 지정한 경로, 임의 text 필드는 받지 않는다. PUT 본문은 정확히 위 4개 필드이며 base는 정확히 3개 SHA 또는 null이다. 신규 생성은 `base: null`, 기존 문서 변경은 마지막으로 수용한 성공 응답에서 추출한 3개 SHA를 사용한다.

```ts
const nextBase: DocumentBase = {
  noteSha256: accepted.noteSha256,
  documentSha256: accepted.documentSha256,
  manifestSha256: accepted.manifestSha256
};
```

PUT 성공 응답에는 `documentJSONBase64`와 `previewPNGBase64`가 없다. GET에는 둘 다 있다. 일반 성공 응답에 `saved`, `resolved`, `reconciliationRequired: false`가 들어온다고 가정하지 않는다. Files의 current.json token, scene SHA, page revision은 이 3개 SHA를 대신하지 않는다.

documentJSONBase64를 해제한 원본은 `format: "ccr.canvas-document"`, `version: 1`의 문서 전체 JSON이다. id/revision/activePageID 및 순서 있는 pages를 갖는다. 각 페이지의 drawingBase64가 PKDrawing 원본이며 별도 중복 전송 필드는 없다. 요청 pages는 JSON과 길이·ID·순서가 같아야 한다. JSON 전체 및 각 drawing/preview의 SHA를 실제 바이트로 검사한다. 응답의 자산 ID는 소문자 정규형이다.

원본 JSON과 모든 페이지 자산을 보존하며 미지원 버전·종류·중첩 필드를 성공 재직렬화로 버리지 않고 거부한다. JSON 변경 시 문서 revision이 전진해야 한다. preview만 변경하면 JSON SHA와 revision은 유지할 수 있지만 manifest/note CAS는 바뀐다. 문서 v1 모델에는 페이지 삭제 연산이 없으므로 기존 페이지를 빠뜨린 PUT을 거부한다. schema 3 페이지의 하향도 거부한다.

## 충돌 조회와 명시 조정의 정확 타입

```ts
type DocumentConflictExpected = {
  activeSha256: SHA256 | null;
  baseSha256: SHA256 | null;
  displacedSha256: SHA256 | null;
  proposalSha256: SHA256 | null;
  historySha256: SHA256;
  bundlesSha256: SHA256;
};
type DocumentConflictMaterial = {
  sha256: SHA256;
  markdownBase64: Base64;
  validDocument: boolean;
  document?: DocumentSummary;
  refusal?: string;
};
type DocumentConflictHistory = {
  recoveryID: string;
  files: Record<string, SHA256 | null>;
};
type DocumentConflict = {
  schema: "ccr.document-conflict/v1";
  id: UUIDString;
  recoveryID: string;
  code: "note_reconciliation_required";
  reconciliationRequired: true;
  publicationAttempted: boolean;
  expected: DocumentConflictExpected;
  materials: {
    active: DocumentConflictMaterial | null;
    base: DocumentConflictMaterial | null;
    displaced: DocumentConflictMaterial | null;
    proposal: DocumentConflictMaterial | null;
  };
  history: DocumentConflictHistory[];
};
type ResolveDocumentRequest = {
  recoveryID: string;
  expected: DocumentConflictExpected;
  decision: "keepCurrent" | "useDisplaced";
};
type ResolveDocumentResult = DocumentSummary & {
  recoveryID: string;
  decision: "keepCurrent" | "useDisplaced";
  resolved: true;
  reconciliationRequired: false;
};
```

`GET /vault/document/conflict?id=<documentUUID>`는 200에서 DocumentConflict를 반환한다. 조정 원장이 없으면 404이며 빈 충돌 객체를 반환하지 않는다. 자료가 없으면 material은 null이다. 바이트가 있어도 전체 문서로 재열 수 없으면 validDocument가 false이며 refusal을 반환하고 document는 없다. refusal 문구를 분기 조건으로 사용하지 않는다.

material.sha256은 Markdown 원문 SHA다. material.document는 JSON/PNG 본문이 없는 요약이다. 큰 후보의 전체 원본은 다음 GET으로 하나씩 읽는다.

```text
GET /vault/document/conflict?id=<documentUUID>&recoveryID=<opaqueID>&material=displaced&sha256=<materialMarkdownSHA>
```

허용 material은 정확히 active/base/displaced/proposal이다. 이 GET의 성공 타입은 DocumentBundle이다. 방금 조회한 recoveryID와 해당 material의 Markdown SHA를 사용한다. query 4개가 모두 필요하며 추가 query나 직접 파일 경로는 받지 않는다. 오래된 ID·다른 문서·SHA 불일치·재열기 불가는 409다.

`PUT /vault/document/conflict?id=<documentUUID>`는 정확히 ResolveDocumentRequest의 3개 필드만 받는다. recoveryID는 opaque 값으로 보존하며 클라이언트가 새로 만들거나 경로로 해석하지 않는다. 현재 서버 발급값은 소문자 UUID다. expected는 GET에서 받은 6개 필드를 null까지 그대로 돌려준다. historySha256과 bundlesSha256은 서버 계산값이며 클라이언트가 다시 만들지 않는다.

```ts
const resolveRequest: ResolveDocumentRequest = {
  recoveryID: conflict.recoveryID,
  expected: conflict.expected,
  decision: "useDisplaced"
};
```

keepCurrent는 현재 active를, useDisplaced는 교환 때 보존한 displaced를 명시 선택한다. proposal/base를 자동 선택하거나 임의 본문을 쓰는 기능은 없다. 성공은 200의 ResolveDocumentResult다. 이 결과의 3개 SHA를 새 base로 사용하며 전체 GET과 로컬 모델/Files 재열기를 검증한 뒤 정상 동기화로 복귀한다.

history.files는 파일명 문자열을 key로 하는 SHA/null 사전이며 서버 내부 경로가 아니다. 현재 파일명은 intent.json/base.md/displaced.md/proposal.md/receipt.json/receipt-unconfirmed.json/resolution-unconfirmed.json이다. 같은 ID·decision·expected를 동일한 최종 상태에서 재전송하면 같은 결과를 반환한다. 다른 decision/expected, 바뀐 현재·보존 자료, 새 독립 미조정 원장은 409다.

선택 결과를 새 Vault 인스턴스에서 문서 전체·Markdown·모든 PNG/drawing으로 재열고 최종 SHA와 경로 identity를 확인한 뒤에만 durable resolved 기록을 쓴다. 후보가 재열리지 않으면 명시 거부하며 모든 자료를 보존한다.

## 오류 DTO와 unknown/held 처리

```ts
type VaultErrorResponse = {
  error: string;
  code?: string;
  reconciliationRequired?: boolean;
  recoveryID?: string;
  publicationAttempted?: boolean;
};
```

전형적인 held 응답은 HTTP 409다. 아래 UUID는 예시이며 실제 원장이나 테스트 성공 영수증이 아니다.

```json
{
  "error": "이 메모는 명시적인 충돌 조정이 필요합니다.",
  "code": "note_reconciliation_required",
  "reconciliationRequired": true,
  "recoveryID": "11111111-1111-4111-8111-111111111111",
  "publicationAttempted": true
}
```

| 응답 | 의미와 다음 동작 |
| --- | --- |
| 400, code=invalid_document | 미지원 키/형식, JSON·자산 SHA/순서 등 입력 검증 실패다. 원본을 보존하고 입력을 수정한다. 모든 400에 code가 있다는 뜻은 아니다. |
| 409, code=document_stale, publicationAttempted=false, reconciliationRequired=false | 교환 전 CAS 또는 revision 불일치다. 제안을 보존하고 전체 GET으로 새 정본을 확인한다. 자동 덮어쓰기는 하지 않는다. |
| 409, code=document_page_loss 또는 document_schema_downgrade, 위 두 flag=false | 페이지 누락 또는 schema 하향을 거부했다. 제안 원본을 보존한다. |
| 409, code=note_reconciliation_required, reconciliationRequired=true | 조정 대기 상태다. 일반 GET/PUT로 해제하지 않고 conflict GET과 명시 조정으로 진행한다. |
| 409, code=reconciliation_candidate_invalid, reconciliationRequired=true | 선택 후보를 전체 문서로 재열 수 없다. 자동 선택·rollback 없이 자료와 held 상태를 보존한다. |
| 409, code=document_api_required | 기존 scene/일반 MD 경로의 문서 우회 접근을 거부했다. 문서 API만 사용한다. |
| 413, code=document_too_large, publicationAttempted=false, reconciliationRequired=false | 문서 요청 wire 한도 초과다. 파일 쓰기 전에 거부한다. |
| 401, error=Unauthorized | 기존 token 인증 실패다. 새 권한이나 인증 fallback을 만들지 않는다. |
| 404 | 문서 없음, 충돌 원장 없음, endpoint 미지원의 문맥을 구분한다. 단독 404로 미확인 게시를 성공 또는 해제로 취급하지 않는다. |
| 503 | Vault 설정을 사용할 수 없다. 원본과 요청 의도를 보존한다. |
| typed 필드가 빠진 409, 알 수 없는 code, 해석 실패·timeout·연결 종료 | 발행 여부를 추측하지 않는다. 초안·전송 원본·기존 base와 요청 의도를 보존하고 재조회한다. |

unknown/held는 클라이언트 상태 이름이며 서버에 이 이름의 enum 필드는 없다. unknown은 응답 유실 등으로 게시 결과를 모르는 상태이고 held는 typed barrier를 확인한 상태다. 두 상태에서 자동 저장과 새 발행을 멈추되 비교·원본 열기·명시 복구 기능은 유지한다. 늦은 성공 응답이나 active/pending SHA 일치만으로 체크포인트를 확정하거나 held를 풀지 않는다.

ACK 유실 시 전체 GET과 필요한 conflict GET으로 현재 원본·모든 자산·원장 상태를 대조한다. 충돌 조회 404와 유효한 전체 GET을 함께 확인하고 보존한 요청 의도에 비추어 수용 가능한 상태인지 판정한다. resolved ACK도 잃었다면 같은 조정 요청의 멱등 재전송 또는 전체 GET으로 검증하며 새 recoveryID를 만들지 않는다. 파일 바이트 보존을 전체 동기화 수용으로 확대하지 않는다.

## 정본 배치와 한도

`CCR Documents/<documentUUID>.md`가 유일한 발행 지점이다. `CCR Documents/Assets/<documentUUID>/<generationUUID>/`에는 다음 불변 세대를 먼저 쓴다.

```text
manifest.json
document.json
pages/<pageUUID>/drawing.pkdrawing
pages/<pageUUID>/preview.png
```

manifest의 정확 타입은 다음과 같다. wire의 documentSha256과 manifest의 documentSHA처럼 서로 다른 필드명을 혼용하지 않는다.

```ts
type DocumentManifest = {
  schema: "ccr.sill-document-files/v2";
  documentID: UUIDString;
  generation: UUIDString;
  documentSHA: SHA256;
  pages: { id: UUIDString; drawingSHA: SHA256; previewSHA: SHA256 }[];
};
```

canonical Markdown은 모든 페이지의 순서·원본/preview 링크를 갖는다. 표시 문자열은 문서 전체 64 KiB 예산에서 파생하며 생략 표시가 있어도 원본 JSON과 모든 자산은 보존한다. 기존 memo suffix는 BOM·CRLF·NFD를 포함해 재작성하지 않는다. 기존 generation은 삭제하지 않는다.

기존 단일 scene과 같은 UUID의 새 문서 승격은 기존 scene과 해당 원본 페이지가 같을 때만 허용하며 memo를 복사한다. 기존 단일 노트와 자산은 덮거나 삭제하지 않는다.

문서 JSON 한도는 16 MiB, 페이지 수는 128개, 페이지 JSON/drawing 한도는 각각 4 MiB, preview 합계는 32 MiB다. wire 상한은 실제 계산한 **67,139,536 bytes (64.029251 MiB)**다.

```text
4 * ceil(16777216 / 3)
+ 4 * floor((33554432 + 2 * 128) / 3)
+ 30328
= 67139536
```

30,328 bytes는 최장 base/SHA/UUID와 128개 자산 메타데이터의 실제 JSON 직렬화 길이다. preview는 분할별 최악 padding을 계산한다. 최대 크기 자료에는 불필요한 slash escaping/pretty print를 사용하지 않는다. 일반 scene의 기존 13 MiB 제한은 그대로다. 충돌 요약 응답은 8 MiB 이내이고 조정 PUT 본문은 16 KiB 이내다. 전체 후보는 분리 GET으로 읽는다.

## 보존·복구와 모델 접합 경계

문서 생성 후 문서 UUID와 모든 페이지 UUID는 기존 scene endpoint, 일반 MD 저장/resolver 및 hardlink 별칭으로 우회 저장하지 못한다. 소유 관계는 canonical 문서와 vault root의 기존 .ccr-save intent에서 파생한다. 새 DB나 상위 원장은 없다.

교환 후 정본 경로·자산·SHA·내구성 확인 실패는 지속되는 typed barrier로 반환한다. 문서 원장은 CCR Documents 부모 교체에도 남도록 설정된 vault root에 둔다. 기존 exchange/atomic preserve와 owner/no-follow/nonblocking/identity 검사를 재사용하고 base/displaced/proposal 원문을 삭제하지 않는다. 비협력 writer의 미래 쓰기나 설정된 vault root 자체 교체를 절대 배제하는 CAS라고 주장하지 않는다.

모델 `0fd008a436252f9b53bfd7cae37dcdf54542fc1f`의 DOC-R1/R2/R3 수리 소스 `782978d7bc574080ae72fd9ebd48b5699473f0ea` / tree `3cb212afd4f4cc05407b4dfb32c403e50c0a5bc9`의 지원 키 표를 직접 대조했다. 부모는 해당 모델의 독립 SOURCE_CLEAR, pbx 결합 검수와 전체 iOS 27개 검사 통과 및 공식 통합을 알렸다. 서버 측에서는 공식 b1b7e30의 CanvasDocument.swift가 782와 바이트 동일함을 확인하고 문서 루트와 모든 중첩 구조의 닫힌 키 17개 그룹이 Node와 같음을 기계적으로 검사했다. 원문 JSON을 재직렬화하지 않는다. 이 모델 수용을 서버의 독립 SOURCE_CLEAR나 Swift HTTP 결합 성공으로 확대하지 않는다.

자유 주석의 author/text를 보존하며 태그 예약 namespace `ccr.sill.card-tag/v1`과 사람이 쓴 주석을 혼동하거나 자동 이관하지 않는다. 최신 공식과의 태그 투영·일반 MD 보호 접합은 별도 검수한다. 서버 GET/저장 성공은 구조·SHA·PNG 검사이며 Apple PKDrawing 네이티브 해석을 대신하지 않는다. Swift 모델/Files의 전체 재열기와 Core의 documentID/pageID/documentSHA 소비는 별도 결합 경계다.

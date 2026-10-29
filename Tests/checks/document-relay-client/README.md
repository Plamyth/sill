# 문서 Relay client 경계

기준 공식 b1b7e30efb32a615eae847cbf8280983fb3b0982이며, wire는 서버9431c0d와 타입31596e6, 원본 HTTP fixture는9c60a7f의 document-wire-v1을 사용한다. fixture는 원본20파일 그대로이며 SHA와 응답 base64 SHA를 검사한다. ACK 유실2건을 실제 응답으로 꾸미지 않는다.

CanvasRelay.swift가 private request/response/session을 재사용하며 CanvasDocumentRelay.swift가 원문·자산 검증을 소유한다. helper 접근 수준을 넓히지 않는다. pbx는 두 기존 target에 새 codec을 등록한다. Store/Workspace·Files 정책·원래 scene/packet 호출은 연결하지 않는다.

API는 `vaultDocument(id:isCurrent:)`, `saveVaultDocument(documentJSON:previews:base:isCurrent:)`, `vaultDocumentConflict(id:isCurrent:)`, `vaultDocumentCandidate(_:material:isCurrent:)`, `resolveVaultDocumentConflict(_:decision:candidate:isCurrent:)`다. isCurrent는 필수 `@Sendable () async -> Bool`이며 호출자가 캡처한 연결 epoch·문서 snapshot의 소유권을 확인해야 한다. 주소/토큰 문자열이 A→B→A로 돌아왔다는 이유로 true를 주면 안 된다. 실제 상태의 소유자는 Store/UI이고 Relay가 새 epoch 원장을 만들지 않는다.

Validated는 모든 페이지 JSON/PKDrawing/PNG 검증 뒤에만 얻으며 summary/document/documentJSON 원바이트/previews를 제공한다. 새 PUT은 원문 bytes를 재직렬화하지 않는다. Summary.base의 note/document/manifest3SHA는 각기 다른 token이며 Files token이나 선택 페이지 SHA로 바꾸면 안 된다. noteSha와 manifestSha는 서버의 opaque CAS 값이며 client가 공급받지 않은 Markdown/manifest 원문을 직접 해시했다고 주장하지 않는다. JSON·drawing·PNG SHA는 실제 바이트로 확인한다.

저장과 resolve는 ACK 요약만 반환하지 않고 전체 GET 재열기까지 성공해야 Validated를 반환한다. 이 결과도 Store의 원본/복구본 보존과 durable checkpoint 완료를 대신하지 않는다. 서버 성공 후 로컬 실패·취소·연결 변경·timeout은 요청 원본/base/intent를 보존해야 한다. typed held와 unclassified409는 자동 해제하지 않는다. ACK 유실 재조정·conflict404와 전체GET 대조·지속 barrier/해제 UI는 Store가 소유한다. 같은 요청의 멱등 재전송이 필요해도 이 codec이 자동 실행하지 않는다.

Conflict는 Codable이며 opaque recoveryID와 expected6개 값을 null까지 보존한다. material 요약으로 선택본을 적용하지 않고 `vaultDocumentCandidate`로 전체 bundle을 읽는다. resolve는 검증된 candidate와 원래 conflict/decision을 요구한다. candidate 미지원·손상·stale면 쓰지 않는다.

실행: `python3 -B Tests/checks/document-relay-client/run.py --output <storage-route 외장 evidence 경로> --sdk-check`. 실제 Relay/URLSession의 URLProtocol 전송, 실제 ImageIO와 PKDrawing, 전체 iOS27 CanvasBridge typecheck를 사용한다. 실제 Node→HTTP 수집 근거를 재사용하지만 새 Swift→Node socket HTTP·UI·기기·Pencil·설치·normalruntime 수용은 아니다. server9c의 독립 검수 P2는 서버 담당 수정/재검수 의존으로 남긴다. 기존8791/8793를 열지 않는다.

# 명시적인 Canvas 충돌 조정 계약

이 DTO와 정책은 부모 조율담당이 저장·클라이언트 결합 P2를 닫기 위해 채택한 최소 계약이다. 사용자가 schema3의 세부값 또는 이 DTO의 필드 자체를 직접 확정한 것처럼 기록하지 않는다. 사용자 승인 목표는 기존 기능 복각·Obsidian 연동·공식 통합이며 계속 유효하다. HTTP 후속 checkpoint의 일시 정지는 부모 조율담당의 진행 순서 조정이고 취소·새 사용자 승인·범위 변경이 아니다.

## 기존 읽기와 쓰기의 held 상태

기존 X-Canvas-Token과 vault 경로 검증을 그대로 사용한다. 미조정 노트의 GET note·canvas 및 일반 note/canvas/block 저장은 409다. 에러 문구를 파싱하지 않는다.

```json
{
  "error": "이 메모는 명시적인 충돌 조정이 필요합니다.",
  "code": "note_reconciliation_required",
  "reconciliationRequired": true,
  "recoveryID": "6b7d652a-8640-4f21-96dd-054c265a40d9",
  "publicationAttempted": true
}
```

recoveryID는 해당 노트의 서버 소유 `.ccr-save-UUID` 지속 원장에서 파생하는 불투명 식별자다. 클라이언트 경로를 조합하지 않는다. active/pending SHA가 같아도 이 상태를 해제하지 않는다. 독점 생성 전 intent를 fsync하므로 최종 receipt 전 중단도 보수적으로 held로 취급한다. 원래 43f의 conflict-preserved receipt도 읽는다. 정상 published-verified 영수증과 게시 시도를 하지 않았음을 확인한 not-published-verified 영수증은 일반 저장을 차단하지 않는다. 마지막 SHA 대조에서 발견한 미게시 stale은 기존 409/재조회 경로를 유지하며, 교환 시도 뒤 held를 SHA 일치로 해제하는 것과 구분한다.

## 읽기: GET /vault/canvas/conflict?id=sceneUUID

인증된 정확한 sceneUUID로 `CCR Canvas/UUID.md`만 찾는다. 미조정 자료가 없으면 404다. 실제 실행에서 생성한 완전한 GET·PUT·성공 응답 예제는 [wire-example.json](relay/test-input/reconciliation-v1/wire-example.json)에 고정한다. 예제는 새 synthetic vault의 실제 파일 교환으로 만들며 가짜 SHA 또는 생략한 material을 포함하지 않는다. 아래는 각 자료의 필드 설명이다.

- 응답: schema `ccr.canvas-conflict/v1`, id, recoveryID, code, reconciliationRequired, publicationAttempted, expected, materials, history.
- expected: activeSha256, baseSha256, displacedSha256, proposalSha256, historySha256.
- materials: active, base, displaced, proposal 각각 원문 또는 null.
- material: sha256, markdownBase64, validCanvas. 유효하면 canvas와 imagePNGBase64.
- canvas: path, noteSha256, sceneSha256, imageSha256, revision, sceneJSONBase64.

실제 부재 자료는 null이고 그 expected SHA도 null이다. 유효하지 않은 자료는 원문·SHA·`validCanvas:false`·`refusal`을 반환하고 canvas/PNG는 생략한다. managed Markdown, scene 버전·kind·geometry, ID/revision, asset 일반 파일·no-follow·제한 크기·SHA 및 기존 PNG validator를 재사용한다. `path`는 결과의 참고값이며 요청 권한이 아니다.

각 Markdown 1 MiB, JSON은 기존 scene 한도, PNG 5 MiB, JSON 원장 64 KiB, 전체 응답 64 MiB다. 원장 폴더 목록 16,384개와 연결된 조정 원장 32개를 초과하면 명시 거부하고 보존한다. 응답에는 원래 네 자료의 원문을 제공한다. history에는 연결된 다른 원장의 recoveryID와 보존 파일 SHA/null만 제공하며 그 정렬된 내용의 SHA를 historySha256으로 사용한다. history는 자동 선택이나 자동 rollback 근거가 아니다.

## 쓰기: PUT 같은 경로

```json
{
  "recoveryID": "0870598e-2939-49c9-8872-d836868aea64",
  "expected": {
    "activeSha256": "bfda7c3e21237d67f70422ce9f74374c780003b05d468e1e69ba84feca0a7c74",
    "baseSha256": "2a781b92bf4e6960ae3ef480d8c57cddb66099ab4877d80d73e12fba5231735e",
    "displacedSha256": "1f9c010bd47a7fae4b03468723aafa5ea6402bef69637ae38c16bf3990fb0ad2",
    "proposalSha256": "bfda7c3e21237d67f70422ce9f74374c780003b05d468e1e69ba84feca0a7c74",
    "historySha256": "4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945"
  },
  "decision": "useDisplaced"
}
```

허용 필드는 이 셋뿐이다. decision은 keepCurrent/useDisplaced만 허용한다. GET의 expected를 그대로 echo한다. UUID·노트 결속, 현재·보존 세 자료와 이전 조정 시도의 SHA를 모두 대조한다. 다른 note의 ID, 새 외부 변경, 임의 경로·text·decision은 거부한다. 선택본이 Canvas로 재열리지 않으면 409 `reconciliation_candidate_invalid`와 `reconciliationRequired:true`, recoveryID를 반환하고 모두 보존한다.

keepCurrent는 현 활성 원문, useDisplaced는 원래 전환 순간에 보존한 원문을 그대로 선택한다. 기존 managed Markdown·메모·JSON·PNG 바이트를 재작성/변환하지 않는다. 명시적인 과거 원본 복구는 일반 autosave의 scene3→2 downgrade 금지와 별개이며, 자동 승격·변환을 하지 않는다.

선택한 바이트는 기존 원자적 교환 또는 독점 생성 primitive로 게시하고 새 ObsidianVault 인스턴스로 Markdown·scene·PNG와 최종 SHA를 확인한다. 각 조정 시도는 같은 노트 폴더의 새 독점 생성 .ccr-save-UUID에 base/proposal/displaced/intent/receipt로 보존하고 intent의 parentRecoveryID로 이전 원장에 연결한다. 조정 실패는 최신 원장의 recoveryID를 typed 409로 돌려주며, 클라이언트는 같은 scene ID로 다시 GET한다. 새 GET의 displaced는 바로 그 실패한 전환에서 보존된 최신 자료이므로 새 외부 편집도 다음 useDisplaced에서 명시 선택할 수 있다. 원래 ID는 부모 원장으로 남으며 이전 expected 재시도는 409다. body DTO는 바뀌지 않는다. 원래 세 자료는 삭제하지 않는다. 선택·재열기·최종 SHA 뒤 resolution.json을 fsync하고 디렉터리를 동기화하며, 반환 전 재검증한다. 기록 fsync/검사 실패 때 자신이 생성한 기록은 자신이 생성한 새 게시 원장 안의 resolution-unconfirmed.json으로 보존하고 held를 유지한다.

성공 200은 다음 구조다. 같은 ID·동일 decision·동일 원래 expected 재시도는 현재 및 모든 보존 자료가 성공 시점과 같으면 정확히 같은 응답을 반환한다. 다른 decision/expected/현재·보존 상태는 409이며 다시 게시하지 않는다. 조정 뒤 일반 저장은 정상 재개하며 이후 정상 저장으로 상태가 바뀌었으면 과거 ID 재시도는 409다.

```json
{
  "path": "CCR Canvas/0e5e23de-e64a-40df-8048-9fac4db87979.md",
  "noteSha256": "1f9c010bd47a7fae4b03468723aafa5ea6402bef69637ae38c16bf3990fb0ad2",
  "sceneSha256": "48a220ef5d8e3305e4df80cf99c7cdfeb202230bb78d94e303a4adde7597c3a2",
  "imageSha256": "c47dd9465c00e9a0c8b85e9ea58d3034a0d23b9cf926113602f3460752a4eb96",
  "revision": 1,
  "recoveryID": "0870598e-2939-49c9-8872-d836868aea64",
  "decision": "useDisplaced",
  "resolved": true,
  "reconciliationRequired": false
}
```

절대 CAS나 미래 외부 writer 배제를 주장하지 않는다. 새 외부 변경이 전환 중 감지되면 추가 시도 자료까지 보존하고 held로 남는다. 파일시스템 자체가 기록·동기화·격리 rename까지 모두 거부하면 durable 상태 보장을 할 수 없으며 오류로 남긴다. 성공 기록은 정확한 새 게시 원장 ID를 결속하고 이전 충돌 원장 계보를 닫는다. 정상 동기화는 그 뒤에만 재개한다. 현재 경로를 자동 rollback하지 않는다. 실제 서비스·사용자 vault·Host·기기·키·권한 변경은 0이다. HTTP/URLSession 후속은 별도 checkpoint와 exact client pin을 사용하며 이 단위·서버 route 검사를 HTTP 통과로 표시하지 않는다.

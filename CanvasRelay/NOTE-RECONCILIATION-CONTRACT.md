# 일반 Markdown의 명시적 충돌 복구

출처는 부모 조율담당이 채택한 최소 API안이다. 사용자가 DTO 세부값을 직접 확정한 것으로 기록하지 않는다. 일반 노트와 PDF 발췌 노트가 미조정 상태에 영구히 갇히지 않고 명시 조정 후 정상 쓰기로 돌아오도록 한다. 기존 Canvas 두 route와 DTO는 유지한다. 새 인증·Host·키·권한은 만들지 않는다.

## 경로와 읽기

기존 X-Canvas-Token으로 GET/PUT `/vault/note/conflict?path=Notes%2Fplan.md`를 호출한다. query는 path 한 개만 허용한다. path는 기존 Vault.resolve의 상대 `.md` 경로다. 절대경로, 빈 구성요소, dot/hidden 구성요소, backslash, NUL, symlink와 비일반 파일은 거부한다. 원문 경로를 임의로 다시 쓰거나 Vault 밖으로 해석하지 않는다. 기존 파일시스템의 case/NFC 원장 결속을 재사용한다.

Vault·노트·자료 경로는 소유자를 확인한다. 일반 노트의 자료 읽기는 root부터 leaf까지 lstat으로 소유자·종류·dev/ino를 기록하고 no-follow FD의 identity 및 읽은 뒤 경로 identity를 다시 대조한다. 부모 경로가 열기 직전에 바뀌어도 다른 파일을 정상 자료로 반환하지 않는다. 본문은 최대1MiB, 원장은64KiB다. UTF-8을 엄격히 읽으며 BOM, CRLF, Unicode 정규화와 공백을 변환하지 않는다.

`CCR Canvas/` 디렉터리 및 그 대소문자·Unicode 별칭은 일반 API에서 거부한다. managed Canvas의 dev/ino와 같은 하드링크도 거부한다. 선택본의 frontmatter에 ccr_scene_id가 있으면 validNote:false로 남겨 Canvas validator를 우회하지 못하게 한다. Canvas 전용 경로에서 조정해야 한다. 일반 API는 서버의 직접 파일 경로와 새 text를 body로 받지 않는다.

## 정확 DTO

실제 파일 교환으로 생성한 완전한 GET·PUT·성공 예제는 `relay/test-input/note-reconciliation-v1/wire-example.json`이다. 생략하거나 가정한 SHA가 없다.

GET 응답은 다음 필드를 갖는다.

- schema: `ccr.note-conflict/v1`
- path, recoveryID, code:`note_reconciliation_required`, reconciliationRequired:true, publicationAttempted
- expected: activeSha256/baseSha256/displacedSha256/proposalSha256/historySha256
- materials: active/base/displaced/proposal
- history: 기존 recoveryID와 files SHA 맵

존재하는 각 material은 sha256, markdownBase64, validNote를 갖는다. UTF-8 또는 일반 노트 후보 검증에 실패한 자료는 validNote:false와 refusal을 돌려주며 원문 바이트는 그대로 보존한다. no-follow·소유자·크기 제한 안에서 안전하게 읽을 수 없으면 전체 GET을409로 거부한다. 부재 자료는 material과 expected SHA가 모두 null이다. expected.historySha256은 연결된 원장 파일 SHA를 묶는다. 전체 응답은8MiB, 원장 목록과 계보는 기존16,384개/32개 한도를 사용한다.

PUT에는 세 필드만 허용한다.

```json
{
  "recoveryID": "e8763436-2948-49e2-a0ff-be8b2cbfc4b3",
  "expected": {
    "activeSha256": "87174762286e6cf14887185297c5e45593b46cb0accace669815fd1287f4793c",
    "baseSha256": "f87f917fc47fe477c599decdf2c4f3e48ccdcb53188a0350903dd18418ebbfe3",
    "displacedSha256": "adfa2b45a2ab030959d1a0fa182772714ecc7af8210bdca294bd00d4392b6b3d",
    "proposalSha256": "87174762286e6cf14887185297c5e45593b46cb0accace669815fd1287f4793c",
    "historySha256": "4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945"
  },
  "decision": "useDisplaced"
}
```

recoveryID는 GET이 준 소문자 UUID 문자열이고 expected는 GET 전체값을 그대로 echo한다. decision은 keepCurrent 또는 useDisplaced다. 현재·원래 세 자료·이전 시도의 SHA 중 하나라도 바뀌면409다. 다른 note에 속한 복구 ID와 추가 path/text는 거부한다.

선택본은 기존 원자 교환 또는 독점 생성 primitive로 게시한다. 새 ObsidianVault 인스턴스가 선택 원문의 정확한 바이트와 SHA를 확인하고 마지막 SHA도 다시 대조한 뒤 durable resolution을 기록한다. 성공 응답은 다음과 같다.

```json
{
  "path": "Notes/발췌 é.md",
  "sha256": "adfa2b45a2ab030959d1a0fa182772714ecc7af8210bdca294bd00d4392b6b3d",
  "recoveryID": "e8763436-2948-49e2-a0ff-be8b2cbfc4b3",
  "decision": "useDisplaced",
  "resolved": true,
  "reconciliationRequired": false
}
```

이후 일반 note GET·쓰기가 정상 복귀한다. 원문은 선택본을 그대로 쓰며 문자열 정규화·Markdown 재생성은 하지 않는다. 빈 UTF-8 문서도 유효하다. active가 삭제돼 null이면 keepCurrent는 거부하고 유효한 useDisplaced를 독점 생성으로 복구할 수 있다.

## 실패와 멱등성

같은 ID·같은 decision·원래 expected의 재시도는 새 pending이 없고 성공 뒤 자료 상태가 같으면 동일 응답을 반환하며 다시 게시하지 않는다. 다른 decision/expected, 다른 note의 ID, 해결 뒤 생긴 새 독립 pending은409다. 새 pending이 있으면 그 현재 ID의 typed409를 먼저 반환한다.

새 외부 경쟁과 조정 실패는 기존 parentRecoveryID 계보를 재사용한다. 원래 base·외부 inode·proposal을 삭제하지 않고 새 시도도 별도 원장에 보존한다. typed409의 최신 recoveryID와 같은 path의 새 GET을 읽어 대조한 뒤에만 다시 명시 선택할 수 있다. UTF-8 또는 managed Canvas 등 선택 불가 후보는409 reconciliation_candidate_invalid다. 자동 선택·자동 rollback·무검증 text 덮기는 없다.

선택본 재열기, 원본과 history 확인, 최종 SHA, resolution 파일·부모 디렉터리 fsync와 반환 전 재검증은 기존 Canvas 계약과 같은 실행 경로다. 파일시스템이 기록·동기화·격리까지 거부하면 완료로 표시하지 않는다. 원자 교환을 절대 CAS 또는 미래 비협조 writer 배제로 주장하지 않는다.

## 검증과 범위

일반 노트의 실제 파일 경쟁, 두 명시 선택과 일반 쓰기 복귀, PDF 발췌 block 수정, 새 독립 원장, 기록 fsync·교환 실패, UTF-8·소유자·크기·경로 경계와 원문 보존을 Node 내장 검사로 확인한다. listener를 열지 않는 server request handler 검사도 실제 HTTP로 표시하지 않는다. 원래 paired HTTP의 CLEAR와 이 새 기능의 source 검수·실행·설치·UI·실기기 수용은 분리한다. 실제8791/8793·사용자vault·Host·기기·설치 변경은0이다.

# 외부 메모와 그림 asset의 저장 보존 계약

독립 검수의 저장 P1·P2와 schema 승격 P2를 수정하는 후보 계약이다. 원본 import와 4a8cc06은 변경하지 않는다. 실제 서비스와 사용자 vault를 갱신하지 않았다.

## 외부 writer와 경쟁하는 노트 저장

hash 확인과 일반 rename 사이에는 비협조 외부 writer를 배제할 수 없다. Node mutex나 추가 hash 조회를 절대 CAS로 표시하지 않는다. 여기서는 다음 파일시스템 연산으로 실제 바이트를 보존한다.

1. 기존 base와 제안본을 같은 폴더의 독점 생성 `.ccr-save-UUID/` 안에 각각 fsync한다.
2. 기존 노트 갱신은 Darwin `renamex_np(RENAME_SWAP)`로 실제 전환 순간의 inode를 `displaced.md`에 보존한다. Linux helper는 `renameat2(RENAME_EXCHANGE)`를 사용한다. 둘 다 일반 overwrite rename으로 대체하지 않는다. 이 후보는 Darwin과 연결 SSD에서 실행 검증했으며 Linux 분기는 실행 검증하지 않았다.
3. 새 노트는 독점 hard link 생성으로 게시한다. 같은 이름이 마지막 순간 생겼으면 외부 파일을 바꾸지 않고 거부한다.
4. 전환 전후 hash와 새 `ObsidianVault` 인스턴스의 note 읽기를 확인한다. Canvas 저장은 같은 새 인스턴스의 JSON·PNG·Markdown 재열기와 모든 SHA까지 확인한다.
5. 전환 순간의 외부 바이트가 base와 다르거나 재열기에 실패하면 409와 복구 폴더를 반환한다. base·외부 inode·제안본은 각각 남긴다. 나중에 기존 fd에 쓰는 외부 변경도 보존 inode에 남도록 성공 뒤에도 자동 삭제하지 않는다.

교환은 원자적이지만 hash 비교까지 묶은 절대 CAS는 아니다. 교환 뒤 경쟁을 발견한 409에서는 활성 경로에 제안본이 이미 있을 수 있다. 이를 저장 성공이나 활성 원본 무변경으로 숨기지 않는다. 새 외부 파일을 덮을 수 있는 자동 rollback·재시도도 하지 않는다. 보존된 후보를 대조해 후속 조정을 해야 한다. `receipt.json`은 `publicationAttempted`, `outcome`, `absoluteCAS:false`, `automaticRollback:false`를 기록한다.

preflight의 알려진 stale SHA나 asset 검증 실패는 노트 게시 전에 거부한다. 교환 API 미지원 또는 helper 실행 실패는 보존된 실패로 반환한다. 호출 결과가 불명확할 때 활성 경로가 그대로라고 추정하지 않는다. 지속적인 외부 쓰기와 crash·전원 손실을 절대 방지한다고 주장하지 않는다.

복구 파일은 원본·외부 변경·제안본을 잃지 않기 위한 보존 자료다. 사용자 판단 없이 자동 정리하지 않는다. 기존 노트 조회는 숨은 폴더를 제외하며 일반 사용자 문서와 섞어 표시하지 않는다.

## Asset 저장과 읽기의 같은 신뢰 조건

신규 생성은 기존 `wx`를 유지한다. 동일 hash 이름 재사용을 포함해 note 게시 전에 O_NOFOLLOW·O_NONBLOCK으로 열고 일반 파일, 제한 크기, 실제 읽은 바이트와 hash를 확인한다. JSON과 PNG의 재열기도 같은 `readAsset`을 사용한다. symlink·directory·잘못된 크기·같은 크기의 잘못된 hash는 거부한다. 이 단계 실패는 이전 정상 note를 바꾸지 않는다. 생성됐지만 참조되지 않은 새 asset은 활성 원본 손상과 구분한다.

## 원격 새 도형의 제한된 목표 버전 승격

`assertAgentRevision`은 원본 scene를 기존 버전으로 먼저 검증한다. `proposedNodes`에 검증 가능한 ellipse·line이 있을 때만 목표 버전 3을 선택하고 같은 scene/node/ink validator로 canonical 복사본을 검사한다. note·box만 있거나 제안이 없으면 버전을 유지한다. unknown 종류·버전과 잘못된 geometry는 거부한다. `nodeEdits.expected`는 원래 버전으로 검증하므로 기존에 없던 새 kind를 수정 필드로 우회시키지 않는다.

원본 packet JSON·잉크·schema와 revision wire 필드는 변경하지 않는다. scene3 목표 승격은 iPad `8509e3c8`의 `CanvasScene.apply`가 제안을 적용할 때 수행하는 계약과 맞춘다. 릴레이의 200은 제안 저장이며 실제 iPad 적용 성공을 대신하지 않는다. 고정 Swift 생성 scene2·line 제안·적용된 scene3 fixture로 이전 409와 수정 뒤 200을 대조한다.

## 실행 경계와 검수

검수 반례와 같은 맥북 연결 SSD에서 실제 별도 프로세스의 in-place·atomic replace와 열린 fd 쓰기를 시험했다. Node 네트워크를 거부하고 정확한 파일 교환 Python helper와 fixture-only writer만 자식 프로세스로 허용했다. Python 표준 ctypes와 기존 `/usr/bin/python3`를 사용하며 새 패키지·계정·권한은 설치하지 않는다. 설치 대상에는 이 tracked helper가 함께 있어야 한다.

고정된 실패 반례 커밋은 `02801079`와 `edab5482`다. 실제 URLSession HTTP harness는 `d95c4f73` 미실행 checkpoint에 그대로 둔다. 이 수정은 HTTP·설치·Pencil·사용자 vault 수용이 아니다. 독립 검수자는 정확한 수정 commit/tree에서 원래 반례와 보존 결과, canonical 승격 조건을 다시 확인해야 한다.

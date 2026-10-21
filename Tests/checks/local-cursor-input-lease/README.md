# 로컬 Cursor 입력 lease의 격리 검사

원담당은 `01a13005-ff61-7780-b0e8-6dc171de1c9d`이며 작업 키는 `cursor-input-lease-20261021`이다. 기준 커밋은 `a2567e7c3147512d4d79d335c4a1f13a640124d2`이다. 쓰기 범위는 `Sources/SillHost/LocalCursorInputLease.swift`와 이 검사 폴더다.

Pstack poteto-mode의 Feature 경로와 Model the Domain 원칙을 적용했다. `Connection` 객체 identity, 불변 `Grant`, `Target` 비교 레코드와 단일 현재 소유 상태로 권한을 표현한다. Ponytail에 따라 기존 동기 게시 closure 계약을 재사용하고 의존성, 타이머, IPC와 OS 주입을 추가하지 않는다.

선행 조건은 부모가 만든 워크트리와 파일별 쓰기 경계 확인이다. 독립 작업은 부모의 IPC 및 창 검증과 이 모델 구현이다. 공유 가변 상태는 Git index이므로 커밋은 지정 경로만 포함한다. 추가 분해는 하지 않는다. 사용자가 새 하위 에이전트와 직접 빌드를 금지했고 후속 독립 검수를 배정했다. ARENA를 실행하지 않는다.

## API 계약

`openConnection()`은 IPC peer를 검증한 부모만 호출한다. 외부 UUID를 입력받지 않는다. 연결과 grant는 Codable이 아니며 생성자는 파일 밖에서 접근할 수 없다. 부모는 연결 객체를 실제 IPC 연결 수명에 결합하고 종료 시 `closeConnection(_:)`을 호출한다.

`claim(_:target:ttlMilliseconds:)`과 `renew(_:ttlMilliseconds:)`은 오류를 던지며 Host가 발급한 grant를 반환한다. TTL 기본값은 500ms이고 허용 범위는 100...2000ms다. 갱신은 새 grant와 세대를 발급하며 이전 grant는 즉시 무효다. 동일 연결의 다른 target claim은 이전 소유자의 Down을 해제한 뒤 전환한다. 같은 target의 중복 claim은 거부하고 renew를 사용한다. 다른 연결은 유효한 소유자를 선점할 수 없다.

`Target`은 `pid: Int32`, `windowID: UInt32`와 opaque String인 `instanceID`, `workspace`, `conversation`, 별도 Host 관리 String인 `captureGeneration`, `videoEpoch: UUID`를 비교한다. windowID는 CGWindowID의 원시 표현이다. 이 레코드의 일치는 선택 권한이나 단일 composer의 증명이 아니다. 원본 선택 검증과 플랫폼 검증은 부모의 책임이다.

`withAuthorization(_:windowCurrent:conversationAuthority:operation:) -> Bool`은 실제 게시 closure가 한 번 실행됐을 때만 true다. `conversationAuthority`는 `(Target, () -> Void) -> Void`이며 검증된 원본 선택의 compare-and-execute 보호 안에서 동기적으로 내부 closure를 호출해야 한다. 거부할 때는 호출하지 않는다. `windowCurrent`는 그 보호 안의 게시 직전에 실행되고, 반환 뒤 모델 상태를 다시 확인한다. 창 검사나 권한 callback이 연결 종료, 만료, 갱신, target 변경, remote 보호를 재진입시키면 이전 grant로 게시하지 않는다. 이 메서드를 기존 `InputInjector.withAuthorization`의 `PostAuthorization` 안에서 호출할 수 있다. 모델은 기존 Sill 원격 입력 경로를 변경하거나 직렬화하지 않는다.

`releaseDown(Connection, Target, ReleaseReason)`은 만료, target 변경, 연결 종료, remote viewer 선점, Sentry 보호에 대해 해당 연결의 Down만 해제한다. 부모는 `connection.id`로 매핑한 주입 소유자만 해제해야 한다. 갱신 전후 동일 연결의 Down은 유지한다. release callback 중 claim과 renew는 거부한다. 다른 연결의 종료나 거절된 다른 요청은 유효한 소유자를 변경하지 않는다.

`expireIfNeeded()`는 주입된 단조 나노초 시계로 기한을 확인한다. `remoteStateChanged(remoteViewerOwnsInput:sentryProtected:)`는 현재 보호 상태를 반영하며 기존 소유자의 Down을 즉시 해제한다. 타이머는 부모가 운영하며 게시·claim·renew에서도 만료를 검사한다. 원격 보호 해제만으로 이전 grant가 되살아나지 않는다.

## 실행과 근거 경계

부모가 정확한 통합본을 Mini에 제공한 실행 경로에서 `python3 Tests/checks/local-cursor-input-lease/run.py`를 실행한다. 실행기는 실제 모델 소스를 테스트와 함께 컴파일하고 실행한다. 대체 lease 모델, 네트워크, 실제 창, InputInjector, HAL, 설치, 기기 조작은 사용하지 않는다. 시계는 수동 전진하며 sleep을 사용하지 않는다. 입력 해시와 종료 결과, 컴파일 실패로 증명한 생성자·불변성·Codable 경계를 출력한다. 개인정보나 credential 원문을 출력하지 않는다.

Companion 0.2에는 선택 변경 generation, revision, compare-and-execute 잠금이 없다. selectedIds가 여러 composer를 나타낼 수도 있다. 따라서 이 모델과 격리 검사는 production 대화 권한을 제공하지 않는다. 부모 production 브로커는 `conversation_authority_unavailable`로 거부하며 입력 활성이나 실제 Unix listener를 광고하지 않는다. `actualInput=0`이다. 실제 입력과 설치·기기 수용을 이 검사 통과로 주장할 수 없다.

## 작업 검사표

- [x] `how` over the affected subsystem. 기존 InputInjector의 동기 PostAuthorization과 소유자별 releaseInput을 확인했다.
- [x] `architect` for parallel design exploration. 사용자 지시에 따라 ARENA와 새 하위 에이전트를 생략하고 직접 계약을 설계했다.
- [x] Write the throughput checkpoint as four todo items. 위 선행 조건, 독립 작업, 공유 상태, 최소 분해에 기록했다.
- [x] Delegate code-writing to a subagent. 부모가 배정한 독립 구현 단위를 직접 소유한다.
- [ ] Verify on the matching surface. 사용자 지시에 따라 컴파일·실행은 부모의 정확한 통합본에서 수행한다.
- [x] Rebase into small, ordered commits. rebase는 공유 워크트리이므로 생략하며 이 단위는 소유 경로 한 커밋으로 반환한다.
- [x] If the design is contested, `interrogate` before shipping. 현재 상충 설계는 없으며 출시는 범위 밖이다.
- [x] Run Opening a PR. 부모에게 소유 커밋을 반환하는 단위로 PR 생성은 범위 밖이다.
- [ ] 독립 검수. 부모가 후속 검수를 수행하며 이 문서는 독립 검수 통과 근거가 아니다.

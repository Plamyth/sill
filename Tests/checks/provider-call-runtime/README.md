# Native provider Runtime 독립 검사

생산 Runtime·LocalAudioRelay·Signer와 Node `0bec7a9970b0bd4e15390012b8ade02ed54605c2`의 private stdio를 실행한다. Core의 세 단계 응답은 결정적인 메모리 transport로 제공한다. 실제 provider 클릭은 실행하지 않는다.

`prepare.py`는 지정한 정확 Git commit의 소스를 읽고 내부 symlink를 보존한다. 테스트 파일은 이 작업트리에서 가져온다. 전체 입력 SHA와 Node 19개 핀을 확인한 뒤 `mini-ephemeral-source`로 실행하고 PID·boot·임시 포트·종료·삭제 영수증을 반환한다. 기존 17648/17649 포트와 설치본 149는 사용하지 않는다.

```sh
python3 Tests/checks/provider-call-runtime/prepare.py \
  --production-repo /Users/ambrion/.codex/worktrees/host-provider-call-20261024 \
  --commit 09715b03cb4421e3dbe3750a871003332f73720f \
  --node-source /Volumes/BT-Workspace/Development-Archives/CCR-Vision/provider-admission-reverify-20261024/input/Node \
  --owner ORIGINAL_THREAD_ID --attempt 5
```

기존 Fixture·Peer·child를 재사용한다. Host identity는 기존 공개 고정 메모리 키를 사용하고 생산 `signRecord`·`verifyRecord` 본문을 선택 컴파일한다. 생산 Runtime 두 개는 전체 본문을 컴파일하며 forwarding Runtime에는 polling 중지 접근자만 추가한다. StreamServer의 217/221 수신·218/222 응답과 Coordinator `handleProvider`는 정확 본문을 선택 컴파일한다. 이 handler 검사에서 연결·페어링 상태만 비활성 fixture다. Node authority는 실제 고정 코드다.

Acquire, Dispatch, Core delivery ACK, 정확한 Node Release 응답, Core result, fresh snapshot 순서를 확인한다. Core 식별값 불일치, 변경된 revision·actor·target, 늦은 취소, 중복 효과, cache miss, requestDigest 충돌, pairing generation, 조회 예산과 독립 217 슬롯을 검사한다.

P2 반례는 같은 actor·pairing에서 실제 relay/자식 boot 교체 후 cache 반환, stale revision 256건 뒤 용량 소진, Recovery/UDS 준비 실패 뒤 미실행 record 정리, 기기당 preflight 4개와 Acquire 이후 tombstone 보존이다. a961 기준의 실패와 수정 후보의 통과를 별도 영수증으로 보존한다.

Socket·PeerAnchor·Recovery는 실제 본문을 컴파일한다. ad hoc 서명한 비활성 검사 프로세스의 OS peer 거절과 준비되지 않은 Recovery의 거절만 수용한다. 실제 설치된 signed peer, Recovery 앱 준비, Keychain, 기기, HAL, UI, 통화 성공의 양성 판정은 0이다. source guard의 생산 checkout 영수증과 Git 없는 Mini의 exact SHA snapshot은 별개다.

Pstack은 Session pickup 후 Feature의 관련 절차와 순차 `how`로 실제 흐름을 추적한다. Prove It Works는 실제 실행 결과와 PID readback에, Test Behavior Not Implementation은 외부 교환·Node 원장·반환값 검사에, Model the Domain은 Core 단계와 필드별 반례 표에 적용한다. Ponytail은 기존 fixture와 표준 라이브러리를 재사용한다. ARENA와 순정 Goal은 사용하지 않는다. 이 worker에는 spawn 도구가 없어 테스트 변경 자체의 독립 검수는 부모가 담당한다.

진행 체크포인트는 정확 후보와 저장 경로 확인, 독립 테스트 워크트리에서 구현, Mini 격리 실행, 테스트 커밋 반환이다. 공유 상태 쓰기는 하지 않는다. 부모의 Vision 구현과 병렬 진행하며 생산 파일은 읽기만 한다. 별도 경쟁 설계·새 의존성·앱 설치·공유 런타임 전환은 범위에 없다.

# 호스트 자동 화면 선택과 source-intent CAS

기준은 공식 `fdc8f486fec4d62fa2ff5018502e9b85ce8d788d`이다. 검사 fixture는 iPad의 고정 Git 객체 `08493bf6436f417ad481e1ef907be1374b03e054`의 source-request 검사에서 필요한 부분만 가져왔다. 최신 iPad 작업공간은 읽지 않았다.

`run.py`는 생산 StreamCoordinator의 kind6·211·launch 수신부, 의도 예약·선택·capture 시작·광고와 StreamServer의 commit·송신·재전송을 그대로 추출한다. 캡처, 화면, 포커스, 네트워크, 오디오 I/O만 inert fixture로 바꾼다. 제스처 자체는 별도 기존 `gesture-drain-scope` 검사 494개로 검증하며 해당 검사의 기대값은 변경하지 않는다.

## 계약

- `WindowList.automaticDisplaySelection == 1`은 kind211 자동 모니터 선택 지원이다. `displaySelection == 1`과 kind211은 그대로 유지한다.
- `selectionRevision`은 영상·입력 세대와 독립된 source 의도 CAS다.
- `DisplaySelection.origin`의 JSON 키는 `selectionOrigin`이다. `human`과 `automatic`만 허용한다. 메타데이터에 null, 잘못된 타입, 알 수 없는 origin이 있으면 거부한다. revision은 비어 있지 않고 UTF-8 기준 128바이트 이하다. automatic에는 revision이 필수다.
- kind6 `SourceRequest`는 기존 StreamSource JSON 루트를 유지한다. 명시적 automatic desktop과 window를 지원하며 none은 거부한다.
- 명시적 automatic은 현재 revision, 실제 connection과 input 참여 세대, 활성 소스 없음, 미결 source/launch 의도 없음, 전환 없음에서만 입장한다. kind211은 현재 inventory UUID와 displayID도 요구한다. kind6 desktop은 현재 host inventory 선택이 있어야 실제 시작한다. topology가 `requiresSelection`을 만들었으면 kind211을 사용한다.
- Android의 기존 자동 복원도 메타데이터 없는 kind211 또는 kind6을 사용한다. host는 자동 여부를 추측하지 않고 기존 호환 규칙으로 처리한다. 이 요청은 활성 소스를 바꿀 수 있으며 새 automatic CAS 보호를 받는다고 주장하지 않는다. 새 보호는 메타데이터를 명시적으로 소비하는 새 클라이언트의 요청에 한정된다.

revision은 새로 수용한 kind6·211(legacy 포함), launch, CLI/로컬의 명시적 선택, 내부의 다른 source 전환, display topology 변경, 현재 의도 소유 peer의 이탈 때 변한다. 거부한 automatic·메타데이터·inventory와 같은 source의 내부 영상 재시작은 revision을 소비하지 않는다. host launchID가 revision의 재실행 간 충돌을 막는다.

## 실행

`verify.py`는 기존 `mini-ephemeral-source run`으로 보낸 한시 사본에서만 실행된다. `.source-hashes.json`에는 보내기 전 파일 전체의 SHA-256을 넣으며 수신 직후·검사 후 대조한다. 출력은 TEST_RESULT JSON의 base64 로그와 SDK 실행파일 SHA로 회수한다. source·출력·cache는 같은 한시 경로 안에 둬 wrapper의 삭제 readback에 포함한다.

`run.py --baseline`은 고정 baseline의 revision 없는 automatic 수용 반례다. `run.py --suite protocol`은 DTO 검사다. 기본 실행은 실제 host 선택 경로이며 `--suite publication`은 실제 queue와 캐시 재전송 경로다. `verify.py`는 이를 기존 gesture/input, monitor, owner 검사와 전체 SillMenuBar SDK에 연결한다.

기존 host-input-focus-fence fixture는 현재 PendingGesture 서명에 뒤처져 독립 컴파일이 실패한다. 이 실패를 통과로 표시하지 않는다. 현재 생산 input/fence/held/chord 호환 검증은 기대값을 유지한 gesture-drain-scope에서 수행한다. monitor fixture의 play 클로저만 기존 제품의 2인자 서명에 맞췄으며 검사 기대값은 유지했다.

이 검사는 설치된 host143, 기기 화면, 실제 네트워크, 신뢰·키체인, 오디오 장치나 실물 수용의 증거가 아니다. 설치·통합과 독립 검수는 원담당이 수행한다.

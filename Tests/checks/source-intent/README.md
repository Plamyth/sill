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

revision은 새로 수용한 kind6·211(legacy 포함), launch, CLI/로컬의 명시적 선택, 내부의 다른 source 전환, 현재 의도 소유 peer의 이탈 때 변한다. 거부한 automatic·메타데이터·inventory와 같은 source의 내부 영상 재시작은 revision을 소비하지 않는다. host launchID가 revision의 재실행 간 충돌을 막는다.

## 실행

`verify.py`는 기존 `mini-ephemeral-source run`으로 보낸 한시 사본에서만 실행된다. `.source-hashes.json`에는 보내기 전 파일 전체의 SHA-256을 넣으며 수신 직후·검사 후 대조한다. 출력은 TEST_RESULT JSON의 base64 로그와 SDK 실행파일 SHA로 회수한다. source·출력·cache는 같은 한시 경로 안에 둬 wrapper의 삭제 readback에 포함한다.

`run.py --baseline`은 고정 baseline의 revision 없는 automatic 수용 반례다. `run.py --suite protocol`은 DTO 검사다. 기본 실행은 실제 host 선택 경로이며 `--suite publication`은 실제 queue와 캐시 재전송 경로다. `verify.py`는 이를 기존 gesture/input, monitor, owner 검사와 전체 SillMenuBar SDK에 연결한다.

기존 host-input-focus-fence fixture는 현재 PendingGesture 서명에 뒤처져 독립 컴파일이 실패한다. 이 실패를 통과로 표시하지 않는다. 현재 생산 input/fence/held/chord 호환 검증은 기대값을 유지한 gesture-drain-scope에서 수행한다. monitor fixture의 play 클로저만 기존 제품의 2인자 서명에 맞췄으며 검사 기대값은 유지했다.

이 검사는 설치된 host143, 기기 화면, 실제 네트워크, 신뢰·키체인, 오디오 장치나 실물 수용의 증거가 아니다. 설치·통합과 독립 검수는 원담당이 수행한다.

## iPad39 정상 초기 topology 회귀와 후속 계약

`topology-trace.json`은 실제143·iPad39의 같은 TLS 연결에서 관측된 다섯 catalog와 원본 SHA를 보존한다. 실제 automatic 제출은 0이었다. `Topology.swift`는 이 valid → nil → valid → nil → 확장39 valid 순서를 생산 handler/select/capture 및 stage.prepare에 주입한다. 물리 display UUID 동일성은 host 내부 계약이며 이 fixture에서는 안정된 identity와 재사용된 다른 identity를 각각 시험한다. 실물 trace에서 host 내부 identity를 직접 측정했다는 뜻은 아니다.

정상 topology는 source 의도 revision, pending human pick, pending launch를 취소하지 않는다. desktop 실행에는 별도 topology 세대가 적용되고 기존 epoch·publication은 닫힌다. window 의도는 자체 stage 생성으로 무효화되지 않는다. stage.prepare의 물리 자원 생성과 외부의 더 최신 source 의도를 구분하며 debounce나 시간 추정은 사용하지 않는다.

호스트가 이미 수용한 automatic desktop만 동일 intent sequence·connection·참여 UUID·displayID·CG display UUID 안에서 현재 inventory로 내부 복구한다. 새 human/launch/CLI·peer 이탈은 이 복구를 폐기한다. 물리 UUID가 없거나 identity가 바뀌거나 기존 ID가 다른 화면에 재사용되면 복구하지 않는다. UUID가 같은 화면의 위치·크기 변화는 허용하며 capture 뒤 현재 geometry를 다시 검증한다. 복구는 새 topology event와 기존 작업 종료에 반응하며 같은 실패를 예약·반복하지 않는다.

최초 입장 전에 stale inventory로 거부된 요청은 계속 거부한다. source revision은 topology만으로 바뀌지 않으므로 클라이언트는 같은 최초 의도·동일 peer/host/local intent·원본 revision 아래 현재 inventory로만 다시 제출할 수 있다. 로컬 전송 수락은 host 입장 또는 VideoEpoch 표시 수렴이 아니다. 클라이언트는 이를 분리해야 하며 source revision이 바뀌었을 때 그 값으로 일반 재base하여 자동 요청을 다시 만들면 안 된다. 호스트 수용 시 자동 의도는 revision을 한 번 소비하고, 이후 정상 topology 복구는 그 수용된 revision을 유지한다. 이 클라이언트 경계는 iPad 원담당이 별도 exact 소스로 검증한다.

이 후속 계약은 앞 절의 topology마다 source revision을 바꾼다는9396 설명을 대체한다. 기존9396 독립 red와 후속 green은 별도로 보존한다. `--coordinator-file`로 immutable9396 생산 coordinator를 주입한 red는 정상화되지 않는 반례를 확인하고, green은 현재 생산 coordinator를 사용한다.

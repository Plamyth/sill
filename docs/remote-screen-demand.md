# 원격 화면 수요 관측

Host는 실제 화면을 선택한 paired TLS viewer의 수요를 기존 Core `command.sock`에 전달한다. Core의 창 가시성, 센츄리 전송 차단, 통화 권한과 독립된 관측이며 입력 허가나 영상 수용 증거가 아니다.

`StreamServer`의 network queue가 전체 목록과 순서를 소유한다. 현재 연결의 incarnation, committed epoch, catalog, publication을 대조하고 캡처 시점에 고정한 창 소유 PID·프로세스 시작 시각·bundle ID 또는 display UUID를 현재 OS 값과 대조한다. 다른 창의 현재 identity를 기존 epoch에 붙이지 않는다. 음성 전용 연결, hello 대기, 미선택 lane은 소비자가 아니다. legacy 연결도 전역 epoch만으로 수요가 생기지 않는다.

연결·선택·commit·신뢰 철회·기존 ClientStats 이벤트에서 관측한다. 통계 내용은 epoch나 실제 표시의 증거가 아니며 해당 연결의 현재 범위를 다시 검사하는 계기다. 소비자의 기한은 자신의 이벤트에서만 갱신한다. pending, 만료, identity 실패, 목록 초과는 불완전 관측이다. 신선한 완전 목록에 현재 대상이 없을 때만 수요가 없다고 판단한다.

## 전송 형식

요청의 정확 필드는 `schemaVersion:1`, `op:"provider.screenDemand"`, `hostGeneration`, `revision`, `complete`, `consumers`다. revision은 양의 UInt64 10진 문자열이며 Host 세대 안에서 증가한다. consumer는 `incarnation`, `epoch:{id,generation}`, `source`, `validForMs`다. UUID는 소문자이며 epoch.generation은 비어 있지 않은 UTF-8 최대128바이트 문자열이다.

window source는 `kind:"window"`, `windowID`, `ownerPID`, `ownerStartSeconds`, `ownerStartMicroseconds`, `bundleIdentifier`다. 프로세스 시작 초는 양의 UInt64 10진 문자열, 마이크로초는0부터999999다. display source는 `kind:"display"`, `displayID`, `displayUUID`다. Core가 현재 대상 display UUID를 확인할 수 없다면 unknown으로 남긴다.

소비자는 최대16개, bundle ID는 UTF-8 최대255바이트, validForMs는1부터5000이다. 요청과 ACK는 줄바꿈을 포함해16384바이트 미만이다. 전송 대기 시간은 남은 기한에서 차감하며 잘린 목록은 complete=true가 될 수 없다.

ACK의 정확 필드는 `schemaVersion:1`, `op:"provider.screenDemand"`, 요청과 같은 `hostGeneration`·`revision`, UUID `coreGeneration`, `accepted:true`다. Host는 같은 관측 소켓에서 coreGeneration이 바뀌거나 ACK가 요청과 다르면 연결을 폐기한다.

`RemoteScreenDemandPublisher`는 기존 `ProviderCallSocket` 인스턴스 하나를 유지한다. 진행 중인 전송 하나와 가장 최신 대기 관측 하나만 보유한다. 오류는 현재 소켓을 폐기하고 새 기존 이벤트에서만 다시 시도한다. 오디오 challenge, grant, lease는 만들지 않는다. 새로운 서버·폴러·타이머도 만들지 않는다.

Core는 검증된 Host anchor와 관측 소켓 세대에 상태를 묶고 같은 revision, 역순 revision, 같은 소켓의 Host 세대 교체를 거절한다. disconnect와 소스 변경은 즉시 재평가한다. 조회 시 기한 확인과 하나의 만료용 one-shot으로 실행 중인 캡처도 비활성 통지를 받는다. 관측 처리로 입력·통화·센츄리 권한을 변경하지 않는다.

## 소스 검사

`python3 Tests/checks/remote-screen-demand/run.py`는 DTO, 엄격 ACK, 실제 비활성 Unix 소켓 프레임, 병합과 취소를 검사한다. Core peer 검증은 주입 fixture다.

`python3 Tests/checks/remote-screen-demand-server/run.py`는 생산자 메서드를 그대로 추출해 가짜 네트워크와 OS identity로 검사하고 실제 Swift encoder의 `WIRE_FIXTURE`를 출력한다.

`python3 Tests/checks/peer-stream-session/run.py`와 `python3 Tests/checks/peer-coordinator/run.py`는 기존 세션·wire·입력 queue와 전체 Host SDK 및 격리 loopback을 검사한다. 실제 Host 설치, 현재 Core 서명 pin, 광학 화면·입력·음성 수용은 별도 검증 대상이다.

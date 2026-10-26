# iPad 오디오 메타데이터 진단

이 변경은 설치되지 않은 소스 후보다. 현재 68 실행과 연결·Host·오디오·권한은 변경하지 않는다. 통합·push·설치는 부모 검수 이후에 별도로 진행한다.

`IPadMicrophoneDiagnostics`는 기존 `Library/Application Support/CCR Sill/microphone-diagnostics.json`의 이벤트 형식과 중복 제거를 유지한다. 같은 폴더의 `audio-metadata-snapshot.json`은 기존 appDataContainer 파일 읽기 경로로 읽는다. 읽기를 위한 서비스·미디어 요청·권한 요청을 추가하지 않는다.

snapshot은 최대 65,536바이트, 최근 attempt 8개, 수신 종류 5개다. 기존 main 통계·정리·초기화와 전경 전이 경로에서 관측한다. 최신 요청 문서 한 개를 합쳐 보관하고 최대 초당 한 번 기존 utility writer에서 원자 쓰기한다. teardown의 최종 상태도 관측하며 연결 교체 시 이전 대기 문서를 폐기한다. 관측 시각은 지연 쓰기 시각으로 바꾸지 않는다. 앱 중지·백그라운드·기존 작업이 없는 동안 주기 갱신을 보장하지 않는다. 오래된 파일은 현재 관측으로 수용하지 않는다.

`generatedAt`은 snapshot 생성 시각이다. `appObservationSampledAt`과 `sampledUptimeNanoseconds`는 앱 상태와 AVAudioSession을 읽은 시각이다. `observedAt`과 `observedUptimeNanoseconds`는 이 연결에서 마지막으로 관측한 메시지 수신 시각이며, 수신이 없으면 null이다. `receivedObservations`는 종류별 누적 메시지 수·수신 시각·Host 헤더 시각과 catalog의 generation·videoEpoch를 보관한다. main 경로의 값은 main에서 메시지를 소비한 시각이다. 이 값은 디코드 수용이나 Host의 현재 HAL 상태를 증명하지 않는다. Host와의 시계 차이는 unknown이다.

PID, 프로세스 진단 observationID·시작 시각, connectionObservationID, 빌드와 검증된 commit/tree를 함께 대조한다. 빌드 소스 식별값이 검증되지 않았으면 commit/tree는 null이다. 진단 시작 시각은 프로세스의 실제 launch 시각을 대신하지 않는다. 재시작 전 파일이나 다른 프로세스의 파일을 현재 실행 증거로 사용하지 않는다.

Sentry와 audioPrivacy는 수신한 캐시 보고이며 현재 HAL·격리 수용과 구분한다. forwarding phase, 사용자 선택 의도, 실제 controller phase와 엔진 상태를 각각 기록한다. 일반 remote·선택형 Sentry·audio ownership의 독립 정책을 변경하지 않는다. default 자동 ON, 빈 intent 자동 request와 suppression 정책은 추가하지 않는다.

attempt의 계수는 이 프로세스에서 관측된 해당 경계의 누적값이다. 없는 계수·선택 필드는 unknown이며 0이나 성공을 뜻하지 않는다. `scopeAtFirstObservation`과 connectionObservationID는 최초 관측 범위를 보존한다. 이후 다른 generation의 상태로 과거 계수를 다시 명명하지 않는다. snapshot에는 마지막 엔진의 render 계수가 남을 수 있으므로 attempt와 formatVersion, 현재 엔진 상태를 함께 읽는다.

`admittedPlaybackPackets`는 admission을 통과한 player 입력이다. `decodedFrames`는 채널 수로 나눈 sample frame 수다. `emptyDecodedPackets`는 길이 0이며 음성 내용이 0인지 검사한 값이 아니다. render의 `copiedFrames`, `silenceFilledFrames`, `underrunTransitions`, `admissionDeniedFrames`는 callback이 메모리에서 센 값이다. 실제 가청 출력이나 정상 route 수용을 증명하지 않는다. callback에서는 파일·진단 이벤트·main 동기 호출을 실행하지 않는다.

capture 계수는 tap 버퍼·입력 프레임·변환 프레임·packet 수와 오류다. send 계수는 제출된 batch·packet·frame 수와 실제 기본 NWConnection의 contentProcessed 성공·실패 batch 수다. contentProcessed는 Host 수신 확인이 아니다. 주입한 시험 Send의 성공을 실제 전송 완료로 기록하지 않는다. Host 미디어 계수는 null로 남는다.

오류는 고정 단계와 숫자 코드로 기록한다. route는 portType만 기록한다. 이름·URL·키·token·credential·사용자 문구·cookie·PCM·실제 음성·샘플 값은 진단 파일에 넣지 않는다. 기존 오류 설명과 Host reason도 진단 이벤트에서는 숫자 코드나 존재 여부로 바꾼다.

검사는 기기·오디오 엔진·녹음·시험음·실연결 없이 합성 입력으로 수행한다. `python3 Tests/checks/ipad-audio-metadata/run.py 출력경로`는 메타데이터의 unknown·중복 제거·빈도·크기·연결 범위, 기준 `14e941099ca5d27bb4c1df171849d601a14a1455`와 8가지 변환의 PCM 바이트 동일성, 실제 AAC decoder의 합성 오류를 검사한다. `check-all.sh`는 기존 admission·lease·desired audio·frame gate·controller 회귀 검사도 재사용한다. iOS SDK 전체 빌드는 별도 unsigned 검사이며 설치 수용이 아니다.

P2 재현 회귀는 `python3 -B Tests/checks/ipad-audio-metadata/repros.py OUTPUT`으로 실행한다. 실제 diagnostics, Sentry network 분기와 main 소비 함수를 추출하며 teardown은 축소 순서와 최종 관측 wiring으로 검증한다. 기기·Host·미디어·권한 시험이 아니다.

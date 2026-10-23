# iPad 공통 음성 계약 소비 검사

기준은 `4eff2c0bd2fa70de9acdd1fdf25d19c97f307012`이다. 공통 DTO는 읽기 정본의 `a14842b3a3a794f51d8ae0d90dbb8182a57ad8ea:Sources/StreamProtocol/AudioForwarding.swift` 468줄 원본 바이트를 사용한다. 같은 커밋의 공식 `Tests/checks/audio-forwarding-wire/Main.swift`에 있는 own intent 7 / binding 11 → resume intent 7 / binding 12 예제와 호스트 원담당의 확정 CAS·freshness·단일 inflight 규칙을 소비한다. Node 서버를 이 검사에서 실행한 것은 아니다.

## 구성

- `IPadAudioForwarding`은 공통 DTO만으로 현재 인증된 기기/연결/화면 범위, 요청 ID, 자기 durable intent, CAS, native binding, 송신 시각 기준 freshness를 관리한다.
- `StreamClient+AudioForwarding`은 기존 `DeviceIdentity.existing()`과 인증된 Mac·저장된 pin을 사용한다. 217은 같은 연결에 한 번에 하나만 보내며, retired 응답은 전송 자리를 비우는 데만 사용한다. 배경/소스 변경으로 상태를 폐기해도 전송 중인 자리는 유지한다. 10초 응답 대기가 지나도 같은 연결의 전송 자리를 임의로 비우지 않는다.
- active/quiescing은 1Hz observe로 확인한다. active 증거는 요청 실제 송신 시각부터 3초만 유효하다. 이전 증거가 만료된 뒤 도착한 응답은 미디어를 복구하지 않는다. quiescing 확인은 10초로 제한한다.
- 공통 계약 지원 여부는 blocked 이후에도 같은 인증 범위에서 기억한다. 명시 재선택은 fresh observe 후 CAS를 제출하며, blocked 자체가 자동 request/resume를 발행하지 않는다.
- 기존 desired 저장과 microphone business policy를 재사용한다. 자체 저장한 input/output과 durable input/output이 다르면 reconnect에서 자동 resume하지 않는다. 다른 기기 intent도 자동 선점하지 않는다.
- 기존 admission lock이 마이크 frame send와 player render 양쪽에서 3초 deadline을 확인한다. 메인 큐가 지연돼도 미디어가 닫힌다. privacy v2 protected·전경·기기 권한·기존 microphone capability와 200/204 계약은 별도 필수 조건이다.
- 공통 계약 지원으로 입력 선택은 가능하지만, 204는 active 후 받은 새 microphone catalog를 확인한 뒤에만 보낸다. WindowList의 optional forwarding 필드는 권위 있는 응답으로 쓰지 않는다.

## 재현

아래 `OUT`은 사용자 승인 외장 경로의 작성자 하위 폴더다. `storage-route path development-archive --project BT_CCR-ipad`로 외장 UUID와 루트 경로를 확인한 뒤 사용한다.

```sh
OUT=/Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/ipad-native-forwarding-20261024/worker-validation
sh Tests/checks/ipad-audio-forwarding/run.sh "$OUT/model"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 -B Tests/checks/ipad-audio-forwarding/adapter.py "$OUT/model"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 -B Tests/checks/ipad-audio-admission/run.py "$OUT/admission-held"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 -B Tests/checks/ipad-audio-admission/nearby.py "$OUT/admission-held"
mkdir -p "$OUT/desired"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer sh Tests/checks/ipad-desired-audio/run.sh "$OUT/desired"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 -B Tests/checks/ipad-desired-audio/intent-adapters.py "$OUT/desired"
python3 -B Tests/checks/ipad-audio-forwarding/build-ios.py "$OUT"
```

순수 상태 검사는 실제 상태 전이와 생성된 control DTO를 비교한다. 어댑터 검사는 제품 어댑터 본문·기존 policy·실제 200/204 송신 함수를 가짜 연결/시계와 결합한다. 기존 desired/권한 fixture에는 공통 허가를 별도로 주입해 그 검사 범위를 유지하며, 실제 공통 handshake는 새 어댑터 검사에서 검증한다. admission 검사는 실제 frame/player 본문을 가짜 엔진에 연결해 메인 큐 지연, 늦은 decode, 이전 ticket, 만료, 시계 역행을 검사한다.

앞선 확장 admission 시험의 시간 초과는 통과로 세지 않는다. 가짜 전송의 동기 completion 재진입과 이전 decode fixture의 소진된 세마포어를 확인했다. decode permit을 반환하도록 fixture를 수정한 뒤 57개 검사가 통과했다. 진단과 최종 로그는 외장 `admission-fixture-diagnosis.json`, `admission-held.log`에 둔다.

앱 빌드는 설치된 Xcode의 실제 iOS SDK가 필요한 Mac 전용 검사다. 이 작업은 허용된 로컬 compact 검사와 실제 iOS 빌드 범위에서 수행했다. 서명·설치·네트워크 로그인·실기기·공유 UI·오디오 실행은 하지 않는다. bootstrap은 기존 프로비저닝 검사와 같은 전부 0인 공개 합성 지문만 넣는다. 이 앱 산출물은 실제 기기용 설치 후보가 아니다.

독립 비작성 검수와 원 통합/설치는 부모 담당이 정확한 커밋으로 이어간다. 이 작성자 검사는 실기기 음성 수용이나 호스트 교체의 근거가 아니다.

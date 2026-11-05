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

## 초기 보호 시작과 권한 복귀 회귀

privacy v2의 `protected=false`는 아직 보호를 시작하지 않은 정상 상태일 수 있다. 인증된 218과 정확한 기기·Mac·화면 문맥이 있으면 새 사용자의 명시적 선택을 217로 요청할 수 있다. 같은 자기 기기와 현재 intent ID/revision/generation·선택이 일치하는 저장 의도만 기존 계약으로 resume한다. 이는 새 권한이나 다른 기기의 intent 선점이 아니다. observe/submitting/quiescing 중 반복된 초기 false catalog는 제어 요청을 취소하지 않는다. 이미 보호되었거나 active인 상태에서 false가 오면 즉시 차단하고, true 복귀만으로 미디어를 재개하지 않는다.

OS 권한창은 기존 catalog를 폐기하므로 동일한 승인 문맥의 명시 선택만 새 observe 뒤에 대기시킨다. 실제 capture/render는 여전히 v2 protected·현재 active binding·기존 scope/grant·fresh deadline이 전부 필요하다. 미지원/누락된 privacy 버전은 선택과 미디어 모두 허용하지 않는다. `adapter-main.swift`는 초기 false, 반복 catalog, 권한 복귀와 fresh218 경합, 자기 durable resume, 보호 상실, 지원 버전 거부를 실제 어댑터 본문으로 검증한다.

## Build 81 이후 context guard 관측

기준은 실제 설치 81의 `d5a591fa8f57c3fb62ae17fea7c62bc1425f1f01`, tree `2ef2bb7d649da07664da3cb38417cb6050cb70f5`다. 기존 `connection81-20261105/after-stop81-audio.json`에서 로컬 desired/capture/engine OFF와 forwarding unknown을 확인했다. `forwardingLastReceived` 부재는 현재 scope의 요약 부재이며 한 번도 218을 받지 않았다는 증거가 아니다. Host intent 25 ON의 원인은 아직 미확인이다. 같은 기기 tap을 반복하지 않는다.

기존 Runtime의 optional `forwardingContextReadiness`는 context guard, 내부 인증 guard 각각의 존재·일치 여부, 현재 context 일치, wire/pending 존재와 forwarding fault를 boolean으로만 기록한다. scope가 달라도 실패한 guard를 관측할 수 있지만 인증·미디어 권한·전송·Host OFF의 근거가 아니다. 기존 인증 함수와 미디어 gate는 바꾸지 않는다. ID·pin·credential·원본 payload·오디오 내용은 새 map과 event에 포함하지 않는다. 과거 attempt scope에는 새 map을 복사하지 않는다.

`cancelDesiredAudioRequest` 진입에서 `explicit_stop_requested` event에 중지 전 같은 guard map을 남긴다. 기존 217 `send` 호출이 실제로 제출된 뒤, 원래 context와 일치하는 첫 경계만 같은 진단 ID의 `explicit_stop_first_217_submitted`에 기록한다. 값은 boolean의 문자열 표현이며 `isObserve`와 `isStopSubmission`을 구분한다. 전달 완료·218 수용·Host OFF를 의미하지 않는다. 연결 교체나 새 ON 선택은 대기 진단을 폐기한다. 상시 polling event는 추가하지 않는다.

Euclid P2 검수에서 기존 event encoder의 sorted prefix 16 때문에 한 event의 24/26필드가 잘리는 결함을 확인했다. 전역 제한과 Runtime 전체 map은 유지한다. 한 번 계산한 map을 `Attempt.recordForwardingGuards`에서 `auth.*` 10개와 나머지 14개로 분리하고 같은 진단 ID의 `explicit_stop_requested`/`explicit_stop_requested_auth`에 저장한다. 첫 217은 `explicit_stop_first_217_submitted`/`explicit_stop_first_217_submitted_auth`로 구분하며, 앞 event에 추가 boolean 2개까지 포함해 정확히 16개다. guard를 다시 읽지 않는다. 실제 제품의 전체 24개 key를 사용한 metadata encoder 검사에서 두 event 합집합, 각 event 한도, 동일 진단 ID, boolean-only 값과 Runtime 전체 map 보존을 검증한다. 이전 12개 metadata 검사는 작은 map만 사용했으므로 이 결함을 검출한 근거로 사용하지 않는다.

P2 보정 후보는 실제 metadata encoder 21개, 모델 191개, actual adapter 99개, desired 모델 57개·adapter 5개를 Mini에서 통과했다. 첫 실행은 필드 보존 검사 뒤 기존 고정 지연 스냅샷 검사가 이전 파일을 읽어 실패했다. fixture를 최대 5초의 실제 저장 readback으로 보정한 뒤 전체 좁은 검사가 통과했고 Mini 임시 소스·출력 삭제를 확인했다. 전역 기록 함수와 Runtime 구조는 `b73ec21e`와 동일하다. Euclid 독립 재검수 전에는 CLEAR로 표시하지 않는다.

소유 작업은 `01a1aa6e-b243-7892-83f7-59fa5b97f2de`, WT는 `/Users/ambrion/.codex/worktrees/ipad-forwarding-context-readiness-20261105`, 브랜치는 `codex/ipad-forwarding-context-readiness-20261105`다. product 변경은 `StreamClient+AudioForwarding.swift`, `StreamClient+DesiredAudio.swift`, `StreamClient.swift`, `IPadMicrophoneCapture.swift`뿐이다. 기준 검사에서 모델 191개·실제 metadata 추출 5개가 Mini에서 통과했고 임시 실행 사본 삭제를 확인했다. 후보의 actual adapter·metadata·desired 검사 영수증은 승인 외장 `forwarding-context-readiness-20261105`에 연결한다. Mini 검사는 Git source-guard 이전 수용이 아닌 exact 파일 해시의 좁은 독립 검사다. 전체 SDK/서명·실기·Host·UI·integration 쓰기는 하지 않으며, 부모가 독립 검수와 `74441294` 이후 통합·82 빌드를 맡는다.

2026-11-05 후보 검사는 모델 191개·실제 adapter 98개·실제 metadata 추출 12개·desired 모델 57개·desired adapter 5개가 통과했다. 첫 후속 실행의 Mini Xcode 경로 부재와 다음 실행의 `/tmp`/`/private/tmp` 모듈 캐시 충돌은 실패 이력으로 보존했다. CLT와 canonical `/private/tmp`를 사용한 최종 실행은 exit 0이며 임시 사본과 검사 출력은 정리됐다. `candidate-source-sha256.json`은 실제 실행한 product/test 파일과 일치하고 `74441294`는 product 4파일을 바꾸지 않았다. 독립 검수는 부모가 지정한 Euclid 대기이며 작성자 검사를 독립 CLEAR로 표시하지 않는다.

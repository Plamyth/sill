# iPad 통화 대상과 Dots 221/222 소비

원담당 `01a16b23-ace2-78d0-a1e0-d0762ff729ca`, 작업 키 `ipad-provider-call-20261024`의 전용 워크트리와 `codex/ipad-provider-call-20261024` 브랜치만 작성한다. 기준은 `fa0525038671ffa87e274e47a8e1c2c5238a2b36`이다.

기본 대상은 Mac 순정 Codex 음성이다. ChatGPT Dots와 Grok Bot을 별도 선택한다. Native/Grok 시작·종료는 미지원이며 해당 대상을 221로 보내지 않는다. 217/218은 제공자 세션 대상을 포함하지 않는 공통 음성 전달이다. Native 통화 권한·센츄리 활성·현재 미디어 경로 성공을 이 구현으로 증명하지 않는다.

Dots DTO는 Host `3dfdef085e6952855c927d980cfaa09434b7784d`의 `Sources/StreamProtocol/ProviderCall.swift`를 그대로 가져왔다. SHA256은 `f3e463444ffb4f8a1242d65350b4de83fc0cba2b7845174117979fe2eb4626fb`다. 공통 파일은 221/222 방향·4096/16384 상한과 optional `WindowList.providerCalls`만 추가한다. 217/218 DTO와 기존 다른 wire 기능은 유지한다. digest 벡터도 같은 Host 커밋의 원본이다.

모델은 Vision `7f8f974eb2eb5df0471bdf7757d65fc1dea4db21:visionOSClient/VisionProviderCall.swift`, SHA256 `2b6646565efc4ab4afd9f0cab6d6ea33d8d1cd702edaabf5114da635c36659aa`를 재사용했다. iPad 문맥에 맞춘 adapter와 수동 기록 조회만 보완했다. Vision 전체 변경은 합치지 않았다.

## 수명과 권한

현재 TLS의 capability 1, 인증된 Mac pin, viewer인 217 등록, 전경, 현재 자기 binding과 freshness가 있어야 명시적 Dots perform을 보낸다. 기존 217과 별도 221 슬롯을 사용한다. 음성 선택·재접속·복귀·인증 복구가 perform을 발행하지 않는다.

자동 query는 원 perform 최초 송신부터 총 10초, 4회, 최소 500ms 간격이다. 자동 query 기한은 최초 절대 기한을 늘리지 않는다. 예산 소진 후에는 자동 재예약을 끝낸다. 사용자가 직접 이전 결과를 확인하면 원 요청 7필드와 digest를 그대로 보내고, 그 단발 query에만 별도 10초 전송 기한을 적용한다. 자동 예산·perform 기한은 재개하지 않는다.

query 결과는 자동·수동 모두 `historicalResult`에 따로 둔다. terminal 캐시 결과도 새 perform, 현재 call session 소유권, 미디어 허가를 만들지 않는다. 원래 perform의 직접 ACK만 명시적 다음 동작의 상태로 사용하며, 실제 동작 시 현재 자기 binding을 다시 확인한다. 다른 Mac에는 원 요청·세션·캐시 결과를 넘기지 않는다.

같은 TLS의 일시적 nil 인증은 물리 슬롯을 해제하지 않는다. wrong ID/digest/old TLS/잘못된 action은 drain하지 않는다. 미검증 exact 응답은 unknown으로 drain한다. 기한 초과와 늦은 ACK는 unknown이며, 타임아웃은 TLS를 폐기한다. 모델 슬롯은 actual TLS 교체 전까지 유지한다.

기존 저장, admission lock, microphone frame, player render와 privacy gate는 변경하지 않는다. `StreamClient+DesiredAudio`와 `StreamClient+AudioForwarding`에는 통화 문맥을 관측하는 hook만 추가한다. 실제 AVAudioSession 경로는 기존 `currentRoute` 이름으로 표시하고, 빈 경로는 미확인으로 표시한다. 부모 소유 `IPadAudioSession.swift`와 BT 패치는 이 작업에서 변경하지 않는다.

## 검사

공식 Mini ephemeral runner에서 다음을 실행한다. 생성된 fixture·모듈·캐시는 작업용 임시 디렉터리와 함께 삭제한다.

```sh
mini-ephemeral-source run --source "$WT" --owner 01a16b23-ace2-78d0-a1e0-d0762ff729ca --job ipad-provider-call-final -- python3 -B Tests/checks/ipad-provider-call/run.py
```

순수 Dots 모델·wire, 실제 iPad adapter 본문, 기존 217 모델·adapter, 기존 admission의 총 다섯 검사군이다. 전송·시계·AV 엔진은 합성 객체이며 실제 기기·Host·오디오·외부 provider 효과는 0이다. 가짜 callback만 검사하는 대신 실제 어댑터 본문과 실제 200/204 송신 경로를 컴파일해 연결한다. 자동 query는 실제 500ms 예약 callback에서도 query만 송신하는지 확인한다.

전체 앱 SDK 빌드는 기존 `Tests/checks/ipad-audio-forwarding/build-ios.py`로 진행한다. `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, generic iOS, `CODE_SIGNING_ALLOWED=NO`이며 합성 bootstrap만 사용한다. 서명·설치·Host 재시작·페어링·BT 경로·전역 오디오는 변경하지 않는다.

독립 비작성 검수·통합·공유 Host 갱신·실기기 수용은 부모 소유다. 이 작성자 검사와 SDK 빌드는 그 완료 증거가 아니다. Native/Grok 새 제어와 실제 센츄리 권한 소비는 확정 후속 계약을 기다린다.

Pstack Feature의 작성 위임 역할로 직접 구현했다. 선행 how/설계·독립 검수는 부모가 소유한다. ARENA와 중첩 spawn은 실행하지 않았다. Ponytail full로 기존 Vision 모델·iPad 저장/미디어·fixture를 재사용하고 의존성을 추가하지 않았다. 독립 Mini 검사와 로컬 SDK 컴파일만 병렬 진행했으며, 공유 기기·서비스 조작은 수행하지 않았다.

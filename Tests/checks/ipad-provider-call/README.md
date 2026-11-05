# iPad native·Dots 221/222 소비

## 2026-11-05 native selector 최종 구현

원담당과 통합 책임자는 `01a13ace-e372-7ed1-9946-149df37ee1c3`다. 최종 작성 범위는 전용 WT `/Users/ambrion/.codex/worktrees/ipad-native-selector-final-20261105`, 브랜치 `codex/ipad-native-selector-final-20261105`다. 기준 `5558f027ae96ab935160f09a9adbf808537dd6af`, tree `f77464936a47c7d3f1024e034d3befac8ae0cfa2`의 기존 11파일 구현을 재사용한다. 아래 과거 Dots 전용·prepared-only 설명은 각 작업 당시의 이력이며 현재 지원 범위를 뜻하지 않는다.

Root `9b094514`의 확정 계약을 소비한다. native control은 schema 2이며 `expectedProviderKind`는 `codex-app-server`다. Dots control은 기존 schema 1의 3필드를 유지한다. 요청 7필드와 digest, 응답 schema 1은 바꾸지 않는다. 현재 peer의 `WindowList.providerCalls == 1`과 명시적인 `providerCallKinds`의 `codex-app-server`가 모두 있어야 native 제어가 가능하다. client는 광고나 새 endpoint를 만들지 않는다.

HostRuntime이 prepared target의 `voiceSessionId`를 검증한다. client prepared ingress는 없으며 순수 decoder를 실제 수신 경로에 연결하지 않는다. client는 직접 perform 응답의 native `started`에 유효한 UUID 원문을 요구한다. stop 요청과 `stopped` 응답은 그 원문 세션에 결속한다. UUID 대소문자를 정규화한 다른 문자열, 다른 provider, 잘못된 요청·digest·TLS의 응답은 슬롯을 해제하지 않는다.

`activeCall`은 최근 명령의 `result`와 별개다. stop이 failed·unsupported·unknown이어도 활성 세션을 보존하며 새 시작과 대상 변경을 막는다. 같은 Mac·같은 세션에 대한 명시적인 수동 stop만 다시 허용하고 자동 perform은 하지 않는다. Dots의 null `stopped`, 자동 query 최대 4회·최초 송신부터 10초·최소 500ms, 기한 후 수동 단발 query 10초, 실제 TLS 교체 전 timeout 슬롯 보존을 유지한다. query 기록은 현재 통화 소유권이나 미디어 허가가 아니다.

native 상태 문구는 Mac의 확정 응답을 설명한다. Dots처럼 화면에서 시작·종료를 관측했다고 표시하지 않는다. 이전 native 응답은 과거 기록으로 표시하고 현재 통화·음성 입출력 미확인을 명시한다. 기존 Dots 화면 확인 문구는 유지한다.

검사는 기존 `run.py`를 Mini ephemeral runner로 실행한다. 기준 후보의 `native-selector-20261105/checks-02.log`에는 모델·wire 212개, native 모델 48개, forwarding 모델 191개, 실제 forwarding adapter 본문 107개, 실제 provider adapter 본문 104개, admission 69개, 총 731개 통과와 삭제 확인이 있다. 첫 `checks.log`의 새 fixture throwing `&&` 구문 실패 이력도 보존한다. 문구 변경 뒤 재검사는 별도 job과 로그를 사용하며 기존 결과를 새 제품 해시의 결과로 표시하지 않는다.

```sh
mini-ephemeral-source run --source /Users/ambrion/.codex/worktrees/ipad-native-selector-final-20261105 --owner 01a13ace-e372-7ed1-9946-149df37ee1c3 --job ipad-native-selector-final-20261105 -- python3 -B Tests/checks/ipad-provider-call/run.py
```

새 로그·소스와 검사 SHA256·공식 삭제 영수증은 `/Volumes/BT-Workspace/Development-Archives/BT_CCR-ipad/native-selector-final-20261105`에 둔다. 합성 전송·시계·AV 객체로 실제 adapter 본문을 검사하며 실제 Host·기기·네트워크·음성 실행을 증명하지 않는다. SDK·독립 비작성 검수는 부모 담당이며 이 작성자는 SDK·서명·push·통합·설치·공유 Host/Core·미디어를 변경하지 않는다. 실제 앱 85/OFF와 실제 native 통화·음성 입출력 수용은 별개다.

2026-11-05 21:22 KST 최종 관련 검사 738개가 통과했다. 모델·wire 212개, native 모델 55개, forwarding 모델 191개, 실제 forwarding adapter 본문 107개, 실제 provider adapter 본문 104개, admission 69개다. `checks-final.log`와 공식 영수증은 exit 0, `SOURCE_UNCHANGED=true`, `SCRATCH_REMOVED=true`, `cleanup_verified=true`를 기록한다. Mini 입력 소스 SHA256은 `f195ceb26003117ea89d1464f1e5637c3721ed33b21ee1239b26a5b5222f68cb`다. 이 결과를 적은 문서 변경 이후에도 제품·검사 파일 해시를 다시 대조한다.

Pstack Feature는 부모의 계약·설계 근거를 재사용하고 위임된 작성자가 직접 diff를 소유하는 경로다. Ponytail full로 기존 상태 모델과 실제 adapter·검사 runner를 유지한다. ARENA·순정 Goal·추가 하위 에이전트는 사용하지 않는다.

- 선행 조건은 exact 기준 commit/tree·clean·독점 작성과 기존 검사 재사용 확인이다.
- 독립 작업은 이 WT의 작성·Mini 관련 검사와 부모의 비작성 검수·전체 SDK다.
- 공유 가변 상태는 이 feature의 기존 11파일과 관련 문서로 한정한다. 부모 전용 `CURRENT-RESUME.md`는 쓰지 않는다.
- 최소 분해는 제품 문구·관련 회귀·문서를 같은 작성자가 닫는 것이다. 새 UI/API 타입과 별도 실행 경로는 필요하지 않다.

## 2026-10-24 Dots 전용 구현 이력

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

## 2026-11-05 native prepared target 준비

확정된 Root `8a59`의 6필드/hash 소비 타입과 순수 iPad decoder 준비는 [NATIVE-PREPARED.md](NATIVE-PREPARED.md)에 기록했다. 실제 native 통화·최종 이벤트·미디어 기능 지원 상태는 바꾸지 않았다.

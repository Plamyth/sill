# 공통 호스트의 실제 앱 조립

작업키host-app-composition-20261021, 원담당01a13005-ff61-7780-b0e8-6dc171de1c9d. 기준6292c2e, 소유브랜치codex/host-automatic-device-access-20261021. 공식068be8f/설치142와 개발 후보를 구분한다. Pstack how/architect/Feature와 독립 검수를 적용하고 Ponytail의 기존 구조 재사용으로 종료·증명·연결 모델을 재사용했다. ARENA는 사용자 금지다.

- [x] Ground: 정본·dirty 소유·설치142·공식ref·Node1f pin과 기존 실제 종료 근거를 확인했다.
- [x] Sketch: AppModel→NativeAudioStartup→실제 factory/runtime→Coordinator/Participants/Protection의 하나의 경로를 조립한다.
- [x] Agree: runtime 전용 작성자는 별도 원담당 계보를 유지하고 공유 Host/입력/메뉴는 부모가 소유한다.
- [x] Implement: 실제 시작/연결UUID 해제/앱 종료, native 배수, HAL/Sentry 증명, 한국어 메뉴와 인증 복귀 요청·결과 조회를 연결했다.
- [x] 검증: 정확한 최종 제품·회귀·전체 SDK와 독립 검수를 통과한다.
- [x] Scrap: Mini 한시 소스·임시 출력 삭제와 source 불변을 확인해 검수 근거를 고정한다.

처리량 종료 조건은 조립된 후보의 타입·회귀·독립 검수이며, 전체 목표 종료 조건은 실제 음성/S23 재연결·다른 물리 기기 인계와 전체 물리 오디오 보호다. 모델 heartbeat와 동일 조건 반복은 만들지 않는다. 이번 소스 검사에서 실물·HAL·설치·공유서비스 변경은0이다.

## 수정과 실행 근거

- 최초 역할 검사에서 WindowList의Sentry optional 필드 누락이 컴파일로 드러나 기존213/214·optional audioPrivacy/sentry 계약을 복구했다. Dock215/216과forwarding217..220은 유지한다.
- native forwarding prepare와 실제 인증 local return의 같은 콜백을 구분했다. native 미디어는 모두 종료하되 Sentry의returningLocal은 인증 복귀에서만 설정한다.
- 실제 입력의 최종 인가·소유·postPair를 보존하면서 remote tag·물리 modifier 격리와 커튼 앱 제외를 연결했다.
- 독립 Russell의 보호 실패 중 legacy ON 재개P1과 정상timer의runtime 무효화P2를 수정했다. 구독자0인 시작 대기까지 동기철회하고 같은capture stop체인에 넣는다. 정상 또는 알려진invalid 상태의timer는변경을방송하지않고실제healthy→failed만전달한다.
- runtime 작성자의052 체크포인트에는accepted transport할당 누락이 있었다. 부모885147a에서6256과같은바이트로복구했다. 회귀child의UUID대소문자문자열비교도공식Node1f의sameUUID규칙으로맞췄다. 실패두건은외장로그/영수증을보존했다.
- Hooke의configure큐대기만료영구차단P2는작성자3d2b014를부모a67cc4f로수용했다. 같은live relay·generation/config의송신전만료만1초후초기포함3번상한으로복구한다. 실제송신실패/거절은재시도하지않는다.
- 앞선SDK3모듈과역할314/grant21/native17/로컬요청10/context36/desktop32가통과했다. 보호동기철회후actualcapture46개와timer초기3개도통과했고, 마지막timer4개·runtime확장·최종SDK는현재재검증중이다. 상세SHA와실행시점은외장검수JSON에고정한다.

## 설치와 실제 수용

실제/공식 Host는142/068be8f로 보존한다. DN32-LIVE·LG·Continuity mic의 공개 HAL master mute/volume 제어 부재와 Hog 내구성 미증명은 보호 미수용 근거다. 기본장치만BlackHole로 바꾸어 보호로 표시하지 않는다. 이 차이가 해소되고 실제 미디어 readback이 있기 전 runtimeAccepted/physicalAccepted는false이며, 코드 검사를 설치 또는 기기 통과로 확대하지 않는다.

## 최종 코드 검수

긴HTTP gate 검사는 첫5초 renew가 native 준비 시작보다 먼저 계산된다는 전제 오류를 고쳤다. 실제 prepare 예산 만료로 forwardingDisconnect가 관측된 뒤 gate를 해제한다. 재시도 상한 검사는 네 번째 시도의 생존 구간에서 FIFO를 풀어 반례를 구분한다. 최종 runtime83개가20261021T012126.369104Z에통과했고소스불변/한시입력삭제를확인했다. 실패011848.330744Z는별도보존했다.

마지막 OS 복귀 검수의 두P2도 해결했다. 동일문구의 실제OS이벤트는강제통지하고,verify의내부실패통지외에timer가changed를중복호출하지않는다. 실제이벤트/첫점검실패의복구는하나의대기Task로모아상태변경guard밖에서sentry.reconcile에연결하며해제/종료시취소한다. 알려진invalid상태와내부실패로새모델/재설정루프를만들지않는다. 실제invalidate/environmentChanged/requestRecovery/timer본문을추출한8개와최종SDK3모듈이20261021T012533.326757Z에서통과했다.

Russell 독립정적검수는 기존 P1/P2와 마지막복구/타이머 조립에 CLEAR를반환했다. Hooke는원담당configure수정과81fa951상한fixture에정적CLEAR다. 두검수는실행을대신주장하지않는다. 최종제품SourceSHA를SDK와대조하고runtimefixture의유일한Coordinator차이는컴파일입력밖의recoveryRequested결합한줄임을이전전체파일SHA와추출context로확인했다.

실제설치142의binary/InfoSHA와공식068be8f는그대로다. 이작업단위의코드검증종료와전체원격/하드웨어수용은분리한다.

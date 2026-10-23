# 실제 참여자의 반복 연결 준비

기준은 `5d2edf3ff209e65f755b5b9bf29a22d0c5e95af3`이다. 실제 등록부와 `NativeAudioStartup`을 호출하며 중지·사실 조회 백엔드만 비활성 합성 구현이다. 추가 참여자나 오디오 의도 원장을 만들지 않는다. `NativeAudioStartup`은 실제 파일의 클래스 선언 전체를 임시 컴파일 입력으로 추출하고 원본 전후 SHA-256을 대조한다. 이 검사에서 사용하지 않는 실행 factory는 항상 거절하는 링크 대역으로 막는다. 실제 factory·PCM·HAL·표면·설치·기기 수용과 구분한다.

`AudioForwardingParticipants.init(registry:)`, `begin(scope)`, `prepare(scope,request,until:)`, `inspect(scope,request,until:)`, `invalidate()`를 coordinator에 결합한다. begin은 반드시 같은 원장의 현재 pending을 독립 확인한 호출자만 수행한다. UUID에 시간 순서를 추정하지 않는다. 소모한 epoch·다른 구성·바뀐 의도/전송은 다시 사용하지 않는다. 이전 비동기 작업의 완료는 새 ticket을 취소하거나 증명하지 못한다. 외부의 오래된 콜백도 현재 scope를 대조한 뒤에만 invalidate를 호출해야 한다.

등록된 Control은 실제 v3 bootstrap을 검증한 경로에서만 `supportsForwarding=true`와 typed `forwardingPrepare` 콜백을 설정한다. 이 콜백은 intentGeneration/bindingEpoch/request를 받아 실제 `forwardingPrepare` RPC로 연결해야 하며 로컬 복귀용 legacy fenceAndQuiesce로 대체하면 안 된다. 기본 false인 구형 Control은 forwarding과 차단 이후 새 로컬 복귀를 열지 않는다. prepare는 같은 요청의 실제 작업을 공유하며 모든 참여자의 준비가 끝난 뒤 inspect를 새로 읽는다. 여섯 종료 사실 중 하나라도 미확인이거나 operation/privacy/boot/revision이 다르면 거절한다. 시간 초과·취소 때도 실제 Control과 native stop의 종료 tail을 보존한다.

일반 isFenced는 해제하지 않는다. 인증된 로컬 복귀는 실제 요청·세대·멤버십의 `beginLocalReturn` ticket부터 인증·중지·HAL 복원·실패 복구를 모두 감싸고 defer에서 `endLocalReturn`을 호출해야 한다. 현재 시작 가능 여부는 `authenticatedLocalReturnUnavailableReason`으로 읽는다. 실제 pending stop이나 활성·불확실한 이전 로컬 복귀가 있으면 거절한다. end는 해당 작업의 증명만 닫고 fence나 tail을 초기화하지 않는다. lease를 쓰지 않는 기존 호출은 보수적인 단일 작업 동작을 유지한다.

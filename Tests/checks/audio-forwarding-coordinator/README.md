# 공유 음성 요청 소비 계약

`AudioForwardingCoordinator`는 기존 원장의 pending 바인딩 하나를 소비한다. 별도 원장이나 전송을 만들지 않는다. 같은 pending은 하나의 작업을 공유하며, 사용한 bindingEpoch로 prepare·commit을 반복하지 않는다. 새 pending은 이전 비동기 호출이 끝난 뒤 시작한다. private pipe의 단일 실행 요청 규칙을 유지하기 위한 순서다.

실제 호스트 어댑터는 현재 구성·fresh snapshot·각 참여자의 prepare/inspect·센츄리와 로컬 음소거의 실제 readback·Node commit을 제공해야 한다. `protectionCurrent`는 실제 보호 상태의 연속 감시 결과를 확인해야 하며 상수 true로 연결하면 안 된다. 구성이나 보호 상태 변경은 즉시 admission을 fence하고 coordinator를 invalidate해야 한다. 같은 private pipe를 호출하는 다른 관찰·등록 작업도 원담당이 직렬화해야 한다. 소비 중의 외부 poll이 동시에 들어오면 기존 `LocalAudioRelay.call`은 busy 상태를 제어권 손실로 처리한다.

`prepare`는 해당 예산 안에서 종료 증명을 반환해야 한다. pending·unknown·blocked 또는 하나라도 미확인인 여섯 사실은 commit하지 않는다. 실패한 pending을 새 ID로 재발급하지 않는다. 같은 기억 의도로 실제 새 전송이 생겼을 때만 새 bindingEpoch를 소비한다. 일시 연결 종료는 로컬 보호나 기억 의도를 해제하지 않는다.

`isCurrent`는 commit된 결정이 현재 구성·보호 증명과 일치하는지 확인한다. 실제 입력·출력 시작에는 해당 전송 종류의 `allowsInput`과 `allowsOutput`을 사용한다. OFF commit과 다른 전송 종류는 admission을 허용하지 않는다. 입력·출력 작업의 모든 비동기 경계에서도 이 조건을 다시 확인해야 한다.

검사는 원래 계약 모델·참여자 영수증·소비 코드를 Swift로 컴파일하고 합성 어댑터로 실행한다. 실제 HAL·센츄리 화면·키체인·서명된 런타임·기기 수용은 증명하지 않는다.

시간 예산이 만료되어도 실제 비동기 호출이 끝나기 전에는 다음 요청을 시작하지 않는다. 실제 어댑터도 commit 호출 진입부터 pipe 전송까지 중간 await가 있다면 전송 직전에 같은 취소·configuration·보호 상태를 재검사해야 한다.

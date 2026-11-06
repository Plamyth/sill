# 네이티브 중계 RPC 순서 검사

맥북에서 이 작업의 정본을 기준으로 실행한다.

```sh
python3 Tests/checks/native-relay-rpc-order/verify-mini.py
```

저장 경로는 `storage-route`로 확인한다. 필요한 입력만 Mac mini의 원 담당 전용 한시적 경로에 전달한다. 실행 도구가 입력 해시, 종료 코드와 원격 삭제 확인 영수증을 남긴다. 맥북 원본과 Mini 입력의 전후 파일 해시도 검사한다. `.git` 없는 입력의 독립 코드 검사이며 Git 이전 수용이나 SDK 빌드 검증을 대신하지 않는다.

`run.py`는 실제 `LocalAudioRelay.swift` 전체에 같은 파일의 검사 접근자만 덧붙여 컴파일한다. 실제 `LocalAudioParticipants.swift`와 `AudioForwardingContract.swift`도 사용한다. 페어링 장치 자료형만 `RemoteAccess.swift`에서 추출하며 검사 인스턴스를 만들기 위해 추출본의 초기화 접근 수준만 조정한다. 공용 `call`, 파싱, 큐와 취소 구현은 바꾸거나 재구현하지 않는다.

비활성 Python child는 stdin과 stdout만 사용한다. 소켓을 열지 않고 오디오, HAL, 앱, 기존 서비스, 기기, 권한 또는 페어링을 조작하지 않는다. 준비 상태 응답은 이 child의 검사 데이터다. 성공 종료 전에 모든 검사 child를 종료하고 기다린다. 검사 프로세스가 실패하거나 제한 시간을 넘기면 해당 프로세스 그룹만 정리한다.

검사 범위는 FIFO 겹침, 전송되지 않은 취소와 마감, 전송된 요청의 실패 시 폐쇄, 전체 대기 정리, sequence 상한, 요청 식별자와 부팅 식별자 및 PID, 엄격한 JSON, 등록된 참여자 콜백, prepare receipt 및 대기를 포함한 최대 5초 예산이다. 마지막 admission은 슬롯 획득 후 실제 전송을 예약하는 MainActor 구간에서만 호출한다. 거절과 전송 전 취소는 sequence를 소비하지 않는다. 실제 coordinator의 scope와 보호 증명 검증은 부모가 연결한다.

Mac SDK 전체 빌드, 실제 Node 계약 상호 실행, 실제 오디오와 기기 동작은 이 검사 범위에 포함하지 않는다.

## Host244 지연 관측

`run.py REPO latency`는 실제 stdio pipe와 inert Python child로 제어 RPC 진단을 검사한다. 느린 응답, FIFO 대기, 미전송 만료·취소, 전송 후 만료·취소, 최종 admission 실패, MainActor 진입 지연과 deadline 뒤 receive를 구분한다. 80개의 빠른 정상 왕복과 80개의 빠른 정상 서버 observe가 진단 예산을 소비하지 않는지, 실패를 반복해도 상한을 넘지 않는지, credential·PCM·임의 method와 응답 본문을 출력하지 않는지도 확인한다. 변경한 전체 StreamServer 파일의 native 구문과 추출한 실제 exchange/수신/응답 메서드를 함께 검사한다.

생산 진단은 `HostLog.shared.append`만 사용한다. RPC가 250ms 이상 걸리거나 실패한 경우만 `audio.trace relayRPC`를 기록한다. `queueMs`는 FIFO 슬롯을 실제 부여할 때까지, `acquiredToWriteMs`는 슬롯 부여부터 writer 시작까지, `writeToReadMs`는 writer 시작부터 비격리 첫 stdio read까지다. 마지막 값은 pipe 쓰기·자식 처리·pipe 읽기의 합이며 순수 Node 처리 시간은 아니다. `readHopMs`는 stdio read에서 MainActor receive 진입까지의 최대 지연이다. `success`는 RPC envelope 검증 성공이며 음성 grant나 업무 명령 수용을 뜻하지 않는다.

`phase`는 queueDeadline/queueCancelled, admission, identityChanged, responseDeadline/responseCancelled, receiveDeadline, pipeClosed, writeFailed, replyValidation, reply 등을 구분한다. 아직 관측하지 못한 시간은 `unobserved`다. timeout 처리가 receive보다 먼저 끝나도 비격리 read 시각을 보존하고, 늦은 MainActor hop은 같은 IPC requestID의 `audio.trace relayRead`로 남긴다. 두 종류를 합쳐 프로세스 수명 동안 최대 64줄이며 새 relay로 교체해도 초기화하지 않는다.

서버 `forwardingReply`도 느리거나 실패한 응답만 기존 64줄 예산에서 기록한다. `firstMainCheckMs`는 수신부터 handleForwarding의 첫 MainActor authority 검사까지이며, `handlerToReplyMs`는 그 검사부터 응답 큐 등록까지, `replyQueueMs`는 서버 응답 큐 대기다. IPC requestID와 서버 control requestID는 서로 다르므로 공통 uptime의 startedNs/receivedNs/endedNs 시간 구간으로 대조한다. deadline, 3초 freshness, FIFO, 인증·authority·장치 보호 동작은 변경하지 않는다.

이 계측은 원인 수정이 아니다. Host244의 5.096초를 단일 IPC timeout이나 마이크 부하로 확정하지 않는다. iPad88 before08/after08은 같은 마지막 observe의 blocked 상태이므로 별도 Host 지연 재현으로 세지 않는다. 실제 Host·기기에서 다음 정확한 한 번의 관측과 원인 판정은 통합 담당 범위다.

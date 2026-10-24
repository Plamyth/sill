# Vision 센츄리 v2 소비자 검사

원장 접수는 Host의 유효한 `accepted=true` 응답으로만 확인하고 원문·공개 binding과 함께 저장한다. 송신 ACK는 접수 확인이 아니다. `accepted=true`인 rejected도 원장 접수와 적용 거절을 구분한다. 이 표시가 없는 saved-only·전송 전 중단·전송 실패·응답 미확인 원문은 같은 TLS session에서 조회로 다시 보내지 않는다. 같은 기기·boot·authorizationGeneration에서 새 sessionID를 받은 재접속 뒤에만 옛 session·revision 원문을 재전송한다. `accepted=true`가 저장된 원문은 같은 session에서 수동 재조회할 수 있다. wire 필드나 query kind를 추가하지 않는다. 미확인 원문의 명시적 재실행 UI도 제공하지 않는다. unknown은 새 ID·변경 CAS·자동 명령을 만들지 않는다.

Host 원장은 128건 bounded eviction을 사용한다는 부모 계약을 따른다. prepare의 원장 삽입·ticket 생성, complete·cancel·revoke가 revision을 새 UUID로 전진시키고 과거값을 복원하지 않으므로, 접수된 옛 원문의 revision은 eviction 후 현재 CAS와 같아지지 않는다. 같은 CAS로 원장만 지우는 TTL·API는 없으며 그런 경로를 추가하면 revision 변경도 필요하다. Host의 413개 검사와 lifecycle eviction 검사는 부모가 전달한 근거이며 이 suite는 그 Host 구현을 실행하지 않는다. 소비자에서는 접수된 동일 session 원문의 unknown 응답에도 새 명령을 만들지 않는지 확인한다.

control이 없거나 알 수 없는 capability이면 trusted 정상 v1 상태의 기존 on-only를 허용한다. off는 허용하지 않는다. 알려진 v2 capability의 잘못된 권한 값은 v1으로 하향하지 않는다. 이 호환 처리는 Vision catalog 수신 경계에서만 수행하며 공유 DTO·fixture의 원본 바이트는 유지한다.

`python3 -B Tests/checks/vision-sentry-v2/run.py SOURCE_ROOT NEW_OUTPUT`은 실제 컨트롤러, 보호 저장 API와 transport adapter, SessionLink를 컴파일한다. Network와 저장소는 비활성이며 실제 Keychain 호출·Host 접속·앱 실행·기기·오디오·입력 효과가 없다. v1 suite의 컴파일·출처·소스 불변 검사기를 재사용한다.

공유 DTO와 fixture·schema는 Host e17ec2abec7d9ea47b6262531674fc17fe22c6af의 허용된 다섯 파일과 바이트가 같다. Host 생산 구현은 포트하지 않는다. 기존 v1 suite는 별도 실행한다.

검사 범위는 명시 켜기·끄기, capability 없는 off 차단과 v1 on 호환, 전송 전 원문 저장과 readback, 저장 실패, 재연결·앱 모델 재생성 뒤 수동 원문 재조회, 옛 session·revision 보존, Mac ID·TLS 지문·기기 지문·boot·권한 세대 변경 거부, 수락과 pending·applied·rejected·superseded·unknown 구분이다. onPrepared 뒤 capture 전 pending과 새 off, 동일 원문 applied, v2 pending/requested=false와 v1의 보수적 경계도 검사한다. 같은 요청의 이전 전송 시도 취소와 deadline이 새 수동 조회에 적용되지 않는지도 확인한다.

보호 저장은 기존 enrollment 저장소의 load/save 클로저와 Keychain update/add·기기 전용·동기화 금지 패턴을 재사용한다. enrollment API가 credential 전용 타입이므로 별도 service/account를 사용한다. 저장하는 것은 공개 binding과 요청 원문뿐이다. recognitionKey·오디오 credential·페어링 개인키를 저장하거나 복사하지 않는다. private 저장 record의 `hasTerminalReceipt`는 기본값과 legacy decode가 false다. true이면 `ledgerAccepted`가 필수이며, 현재 trusted 요청의 유효한 `accepted=true` 응답에서 applied·rejected·superseded가 확인된 경우에만 원문과 함께 저장한다. applied의 phase·desired 검증은 그대로 유지한다. accepted rejected는 접수된 종료 실패이며 성공으로 표시하지 않는다. pending·unknown·접수 미확인 응답은 종료 표시를 만들지 않고, 이전 종료 표시도 해제해 보존한다. 최대 64건이 차면 새 명시 명령을 저장할 때 가장 오래된 종료 확인 기록 하나만 새 record와 같은 save/readback으로 교체한다. 미접수·pending·unknown·legacy 기록은 교체하지 않으며 모두 미해결이면 보수적으로 거절한다. wire 7키와 Host DTO는 바꾸지 않는다. 256회 명시 on/off와 128회 뒤 JSON 저장 복원·앱 모델 재생성, 혼합 기록의 바이트 보존, 교체 실패 전송 0을 비활성 검사로 확인한다.

검증 결과는 consumer 코드와 비활성 소비자 계약의 근거다. 실제 TLS·Host 213/214 v2 배선, 보호 표면과 capture, Keychain 쓰기, 설치 UI, 실물 Vision 수용은 부모 담당의 별도 검증 대상이다. 수동 조회는 기존 원문을 재전송한다. 연결·catalog 수신이나 앱 재시작은 자동 전환이나 재전송을 만들지 않는다. 새 상주 타이머는 없다.

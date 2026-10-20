# 원격 재생 gain 검사

워크트리 루트에서 `python3 Tests/checks/vision-output-gain/run.py`를 실행한다.

실제 `VisionAudioGain.swift`, 순수 PCM 상태 모델, `VisionAudioPlayer.swift`의 renderer callback 본문을 읽어 Mini의 stdin으로 전달한다. gain 상태는 실제 구현을 실행하고 callback은 비활성 버퍼와 출력 대역으로 호출한다. 프로젝트 파일을 생성하거나 기존 다른 테스트를 실행하지 않는다.

검사 대상은 기본값, 각도 비례식, 경계, 비유한 입력 거부, 확정과 취소, 여러 창과 같은 owner의 세대 교체, 오래된 Ticket 거부다. 조절 잠금을 잡은 상태에서도 gain 읽기가 완료되는지 확인한다. 동시 갱신과 읽기 중 값이 유한한 0...1 범위를 유지하는지도 검사한다.

PCM 검사는 mono와 stereo의 gain 1 보존, 0.5 곱셈, gain 0의 정확한 양의 0, 실행 중 gain 변경, 기존 비대기 잠금 실패, 미디어 grant 취소와 세대 교체, 작은 버퍼와 부족한 채널을 확인한다. 실제 하드웨어 wrapper는 실행하지 않는다. 기반 커밋의 하드웨어 및 순수 버퍼 파일과 byte 단위로 대조하고 Player 변경이 최종 gain 적용뿐인지 검사한다.

두 Vision 앱 target과 생성 스크립트에서 파일 멤버십도 검사한다. `--emit-swift`는 동일한 검사 입력을 stdout에 출력하며 Mini 실행은 하지 않는다.

검사 종료 후 `receipts`에 로컬 JSON 영수증을 남긴다. 영수증에는 실행 커밋, 파일별 SHA-256, 송수신 Swift 입력 SHA-256, callback SHA-256, 소스 불변성, Mini 임시 출력 경로와 제거 확인이 들어간다. Mini의 소스는 메모리 입력으로만 전달하고 컴파일 출력과 모듈 캐시는 해당 검사 전용 임시 경로에서 제거한다.

컴파일 예산은 180초이고 순수 검사 실행 예산은 60초다. Mini 도구의 대기를 포함한 전체 호출 예산은 300초다.

Pstack Feature 경로와 Ponytail full을 적용했다. Model the Domain 원칙으로 Ticket과 시작값을 Adjustment에 묶었다. Test Behavior, Not Implementation 원칙으로 공개 API와 실제 sample 쓰기의 결과를 검사한다. ARENA는 사용하지 않는다.

실제 재생, Mac 물리 출력, 마이크, 권한, 의도, 장치 설정, HAL, 앱, 설치, 재시작, 시뮬레이터, 전체 visionOS SDK 빌드는 이 검사 범위에 없다. 이 영수증은 source-guard 작업 이전 수용이나 독립 검수 승인을 뜻하지 않는다. 부모가 제스처 연결, SDK 빌드와 독립 검수를 이어간다.

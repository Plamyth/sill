# Obsidian 릴레이 소스 편입 후보

기존 `relay/`의 tracked 41개 파일을 `CanvasRelay/relay/`에 바이트와 Git 실행 모드를 그대로 편입했다. 원본 저장소는 수정하지 않았다. 출처 commit/tree와 파일별 Git blob, SHA-256, 크기, 모드는 `SOURCE-MANIFEST.json`에 있다. `node CanvasRelay/check-import.js`로 편입 상태를 검사한다. 후속 기능 변경 전의 기준 커밋에서 실행한다.

## 독립 실행과 검사

Node 내장 모듈만 사용한다. `node --test CanvasRelay/relay/canvas-diagram.test.js CanvasRelay/relay/braintrinity-projection.test.js CanvasRelay/relay/canvas-schema.test.js`로 네트워크 listener 없는 검사를 실행한다. `canvas-schema`는 인메모리 HTTP request 이벤트와 임시 fixture 파일, 주입한 가짜 RPC를 사용한다. 실제 서비스나 사용자 vault에는 접근하지 않는다. 환경의 fixture 출력 변수와 인증 관련 변수는 전달하지 않는다.

기존 `relay/start.js`는 현재 사용자 token 파일을 읽고 8791 listener를 연다. 이 작업에서는 실행하지 않는다. `relay/server.js`를 직접 실행하면 환경 설정을 사용하는 서버가 시작된다. 정식 전환 때 기존 담당이 저장 경로, token 참조, vault와 서비스 소유권을 확인해야 한다. 이 편입 커밋은 서버 설치나 전환을 수행하지 않는다.

## 안전 제외

`server`, `control-room-events`, `control-room-incremental`, `control-room-projection`, `obsidian-vault`, `canvas-limits`, `vault-block-edits` 테스트 파일에는 실제 loopback listener, socket 또는 fetch 시험이 포함되어 이번 무네트워크 검사에서 제외했다. `codex-delivery`의 자식 프로세스와 실행 경로 시험, `control-room-sources`의 설치 Core 참조 및 helper 시험도 제외했다. `control-room-public-relay`는 별도 이벤트 경로 검토가 남아 이번 최소 편입 검사에서 실행하지 않았다. 파일 자체는 tracked 원본이므로 그대로 보존했다. 선택한 세 파일만 통과한 것을 전체 릴레이 검사 통과로 표시하지 않는다.

Swift UTF-8 동등성 검사는 `CCR_PELE_SWIFT_OUTPUT`의 실제 writer 산출물이 없어 원래 테스트가 skip한다. 임의 값을 만들어 수용하지 않는다.

## 포함 범위

`relay/` 안의 tracked 코드, 테스트, vendor와 합성 test-input만 포함했다. 앱과 진단 프로젝트, `.git`, `node_modules`, 환경파일, 런타임 token·키·설정, 사용자 데이터는 편입하지 않았다. 기존 소스에 적힌 기본 경로는 실행 설정 복사가 아니다.

Pstack Refactoring의 동작 고정·원본 대조·실제 검사 경로를 적용했다. Ponytail은 기존 코드를 그대로 재사용하고 새 의존성을 추가하지 않는 선택에 적용했다. ARENA와 순정 Goal은 사용하지 않았다. 현재 런타임에는 `spawn_agent`가 없어 독립 검수는 부모가 정확한 후보 커밋에서 수행해야 한다. 공식 merge와 실행 수용은 미완료다.

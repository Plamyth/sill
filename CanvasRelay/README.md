# Obsidian 릴레이 소스 후보

원본 그대로의 첫 편입 커밋은 `f875454f16566c417e6549d40e508c19aadc589e`, tree는 `ff10e0aaef534497e99352de78b4a773dc0599d5`다. 기존 tracked `relay/` 41개 파일, 총 557,488바이트의 Git blob, SHA-256와 모드가 일치했다. `SOURCE-MANIFEST.json`은 그 불변 기준이다. 현재 후속 구현의 파일 해시와는 구분한다.

```sh
node CanvasRelay/check-import.js f875454f16566c417e6549d40e508c19aadc589e
```

인자 없이 실행하면 현재 작업 파일을 첫 편입본과 대조한다. 후속 기능 변경이 있으면 해당 파일에서 실패하는 것이 정상이다. 첫 커밋에는 manifest, 이 설명의 최초 버전과 검사기만 추가했다. 앱·진단 프로젝트, `.git`, `node_modules`, 환경파일, 런타임 token·키·설정과 사용자 데이터는 편입하지 않았다. 원본 저장소는 수정하지 않았다.

## 후속 scene3 구현

지원 계약과 iPad 접합 위치는 `CONTRACT.md`에 있다. 기존 scene3 검사는 Node 내장 모듈을 사용했다. 후속 저장 보존 수정은 기존 Python 표준 ctypes의 원자적 파일 교환 helper도 사용한다. 상세 경계와 추가 검사는 `SAVE-CONTRACT.md`에 있다. 다음 검사는 별도 synthetic HOME과 외장 TMPDIR에서 실행했다. 실제 네트워크·서비스·vault는 사용하지 않았다.

```sh
node --test --test-skip-pattern='authenticated HTTP|authenticated canvas HTTP|isolated loopback HTTP' CanvasRelay/relay/canvas-diagram.test.js CanvasRelay/relay/braintrinity-projection.test.js CanvasRelay/relay/canvas-schema.test.js CanvasRelay/relay/canvas-scene3.test.js CanvasRelay/relay/obsidian-vault.test.js CanvasRelay/relay/canvas-limits.test.js CanvasRelay/relay/codex-delivery.test.js CanvasRelay/relay/control-room-public-relay.test.js
```

실제 실행 영수증은 작업 루트의 `relay-integration-evidence/guarded-tests.json`이다. 실제 실행에서는 추가 preload로 `listen`, `connect`, `fetch`, datagram과 자식 프로세스를 거부하고 test isolation을 none으로 설정했다. 세 HTTP 검사는 listener 또는 fetch를 사용하므로 이름으로 제외했다. 나머지 `server`, `control-room-events`, `control-room-incremental`, `control-room-projection`, `control-room-sources`, `vault-block-edits` 테스트 파일은 listener·socket·설치 Core·helper 경로 또는 별도 검토 범위 때문에 실행하지 않았다. 전체 릴레이 검사 통과를 뜻하지 않는다. Swift UTF-8 동등성은 실제 `CCR_PELE_SWIFT_OUTPUT` writer 산출물이 없어 원래 테스트가 skip한다.

## 실행 경계

`relay/start.js`는 기존 사용자 token 파일을 읽고 8791 listener를 연다. `relay/server.js`를 직접 실행하면 환경 설정을 사용하는 서버가 시작된다. 이 작업에서는 둘 다 실행하지 않았다. 편입과 격리 파일 검증을 실행 서비스 전환·설치·실기기 수용으로 표시하지 않는다. 실제 PNG는 iPad가 제공해야 하며 이 작업은 바이트 보존만 시험했다.

Pstack Refactoring의 원본 동작 고정·대조·실행 검증을 적용했다. Ponytail은 기존 validator와 vault CAS를 재사용하고 의존성을 추가하지 않는 선택에 적용했다. ARENA와 순정 Goal은 사용하지 않았다. 현재 런타임에는 `spawn_agent`가 없어 독립 검수는 부모의 정확한 후보 커밋 검수로 남긴다. push·PR·공식 병합·설치·런타임 전환은 수행하지 않았다.

저장 검수 수정의 실제 회귀 영수증은 `relay-vault-fix-20261029/evidence/run-final.json`이다. 이 실행은 Node 네트워크를 거부하면서 정확한 파일 교환 helper와 fixture-only 외부 writer만 허용했다. 이전에 모든 자식 프로세스를 거부한 실행과 구분한다.

## 명시 충돌 조정 검사

부모 조율담당이 채택한 DTO와 상태 계약은 `RECONCILIATION-CONTRACT.md`, 완전한 실행 예제는 `relay/test-input/reconciliation-v1/wire-example.json`이다. `python3 CanvasRelay/run-checks.py --output <승인된_검사_출력_절대경로>`는 기존 132개 통과 검사와 새 조정 반례를 같은 synthetic HOME/TMPDIR에서 실행하며 listener·connect·fetch·datagram을 거부한다. `--focused`는 새 조정 경계만 실행한다. 실제 파일 교환 helper와 fixture writer만 허용하고 각 실제 PID·종료·부재와 파일/인자 해시를 기록한다. socket 없는 server.emit 검사는 실제 HTTP 또는 URLSession 통과가 아니다. HTTP 후속은 보존된 checkpoint에서 조율한 뒤 이어간다.

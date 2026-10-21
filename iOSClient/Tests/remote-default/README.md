# Verify iPad startup and CCR record retirement

Run these commands from the repository root.

```sh
python3 iOSClient/Tests/remote-default/run.py
python3 iOSClient/Tests/remote-default/policies.py --focused
python3 iOSClient/Tests/remote-default/compare.py
```

`run.py` extracts the production startup methods, wired fallback method, and the home-security/fallback segment of `sessionEnded`. It compiles these with the real `DiscoveryPolicy` and deterministic clock, connection, and identity stand-ins. The iOS conditional branch is selected explicitly for this macOS logic test. No network connection or Keychain operation occurs.

`policies.py --focused` compiles the real protocol value types, `SavedMacs`, `DiscoveryPolicy`, and `RemoteDialPolicy`. It tests automatic trust selection and CCR retirement, including the supplied pairing chronology. It also extracts the production retirement integration method. Its session and preferences stand-ins verify the admission, signature, preference, active-pairing, and persistence boundaries.

`compare.py` runs the existing `policy`, `home-device`, and `remote-rules` suites against both HEAD and the working sources. It preserves their logs and compares the exact failing assertions. A successful comparison means the failure lists match. It does not mean these older suites pass.

Temporary sources, executables, and compiler caches stay below this directory. Temporary build directories are removed after each run. Existing test files outside iOSClient are read only. No Mac host source is compiled. The comparison reads committed protocol/client sources with `git show`.

These tests prove client decisions and persistence boundaries through stand-ins. They do not prove a real TLS handshake, USB routing, remote service availability, physical iPad behavior, or installation. Full native iOS compilation requires an iPhoneOS SDK.

Mini 임시 소스에서 Git 없이 비교할 때에는 정확한 기준 ref의 입력 파일을 상대 경로 그대로 export하고 `CCR_REMOTE_BASELINE_DIR`에 그 루트를, `CCR_REMOTE_BASELINE_REV`에 정확한 commit을 지정한다. 비교기는 기존 실패 목록도 JSON으로 출력한다. 이 snapshot은 테스트 입력이며 source-guard의 Git checkout 동일성 수용을 대신하지 않는다.

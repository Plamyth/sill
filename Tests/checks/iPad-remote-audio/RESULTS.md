# Verification record

The implementation is based on `951af410413493816d10a40acf8fc3e93cabe6f2` in the exclusive `codex/ipad-remote-audio-optin` worktree. Only `iOSClient` and `Tests/checks/iPad-remote-audio` are owned by this sidecar.

The deterministic executable passed 86 behavior assertions. These exercise the actual consent controller, the full audio adapter, the extracted connection setter and initialization, and the player's receive, stop, and append methods with fake engine setup and decoder. All 11 compiled mutants failed behavior assertions. The 11 supplementary wiring checks also passed. Run `Tests/checks/iPad-remote-audio/run.sh --mutants` to reproduce.

The generic iOS arm64 Debug build passed with signing disabled. The build includes the real SwiftUI settings control, client, player, video, and touch code. It does not prove physical interaction or audible output. Build logs are kept at `.build/checks/iPad-remote-audio/ios-build.log`. Behavior logs are kept at `.build/checks/iPad-remote-audio/behavior-tests.log`.

No physical app was installed or launched. No Mac host was activated. Nothing was pushed and no PR was opened. Independent review, real iPad sound and route checks, and device video and touch regression checks remain pending with the integrating owner. The host lifecycle review remains outside this sidecar's acceptance.

The source change to `StreamClient.handle` now carries the actual NWConnection into audio and window-list handling. A later integration with the Vision owner's analogous origin change must preserve both call sites, including kept messages after handover.

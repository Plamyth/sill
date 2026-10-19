# Native local-return participant source unit

Parent invokes `python3 -B Tests/checks/local-audio-participants/run.py ROOT ISOLATED_OUTPUT`.
An existing empty parent output directory is accepted. All SwiftPM scratch/cache/config/security
paths and module caches are inside that output. The runner emits the existing host-privacy package (including all baseline assertions), adds
these participant checks, runs it with an explicit 240 second budget, and writes `result.json`,
`checks.log`, and `SUITE_RESULT`. This worker did not execute that runner or any build/test.

The emitted `swiftpm/debug/HostPrivacyChecks` supports inert interop:

```
HostPrivacyChecks --emit-request REQUEST_JSON S23_BOOT_UUID
HostPrivacyChecks --read-receipt REQUEST_JSON NODE_RECEIPT_JSON
```

Both commands use the production Swift Codable types and `receipt.proves(request)`.
The first creates UUID operation/generation values and a relay request at revision `"2"`.
Pass the boot UUID of the independently constructed inert Node participant. To test another
revision/budget, decode/encode a request through these same production types in the harness.
The second exits nonzero for malformed/missing/null/false or mismatched facts/identity.
It validates an isolated receipt, not registry membership, OS authentication or cross-process trust.

Production AppModel creates NativeAudioStartup, whose trusted native registration is installed
before construction. StreamCoordinator installs actual quiesce and readback callbacks. The
factory consumes the same registry through HostAudioPrivacy.requestLocalReturn. The required
relay has no authenticated production connector, so menu and direct requests refuse before
OS authentication and HAL restoration. No endpoint, token, new protocol kind or resume bridge
is introduced. Admission remains fenced after an uncertain or completed operation.

The selected parent design is a typed native owner registry, replacing coverage enum trust.
The rejected alternative is a distributed zero-count journal without trusted ownership. Pstack
poteto/architect and deslop source review followed the fixed parent contract sequentially.
The no-comments independent reviewer was deferred under the explicit no-children instruction;
diversity is reduced. Ponytail full reuses NativeAudioStartup, existing quiesce,
Foundation Codable, ContinuousClock and checked continuations. Independent review and parent
isolated tests/full SDK compilation are required before integration. Installed, physical device,
all-endpoint silence, S23 phone hardware and Sentry acceptance are not established by this unit.

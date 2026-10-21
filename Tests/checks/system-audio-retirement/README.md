# System audio retirement counterexamples

Run on the parent-approved compute host with the exact ROOT source and an existing empty OUTPUT directory outside ROOT:

```sh
python3 -B "$ROOT/Tests/checks/system-audio-retirement/run.py" "$ROOT" "$OUTPUT"
```

The runner extracts the production class fields, start, stop, subscription boundary and error delegate verbatim. It removes only the PCM sample callback and supplies inert ScreenCaptureKit stand-ins. No ScreenCaptureKit or HAL is imported or called. Checked continuations hold starts and stops without timing sleeps. A held serial queue checks the retirement barrier. Compiler caches, temporary files, executable, logs and result.json stay in OUTPUT. Set SWIFTC to select the parent's Swift compiler.

The assertions cover clean retirement, empty stops, failed stops followed by clean generations, overlapping held older stops with successful or failing results, failed starts, unsolicited errors, stale delegates, queue draining and stop during an unsettled start. Ordinary remote audio must still start after unknown retirement. The actual PCM callback and coordinator are outside this fixture's runtime coverage.

The test commit precedes the production fix. Runtime results are deliberately uncollected here; the parent owns execution, full SDK compilation and independent review. On the baseline, assertions such as `new successful stop cannot erase old failed stop` must fail. The fixed source must finish with `RETIREMENT_RESULT assertions=31 failures=0`. This expected count has not been executed here.

Pstack Bug fix steps: reproduce using the executable fixture; narrow the shared retirement overwrite; implement the smallest state change; rerun the same fixture; keep the counterexample commit before the fix; skip PR opening because the task prohibits push. Runtime reproduction and independent review remain parent gates under the explicit local static-only scope. Ponytail reuses the existing lock and capture queue.

Retirement remains conservative for failed starts, unsolicited error callbacks, failed stops and stops initiated before start settles. These generations stay unresolved for this capture object's lifetime. Subsequent remote audio is allowed, but local return cannot claim all workers exited. Successful overlapping older stops can remove only their own generation, after their queue barrier; an empty stop cannot retire anything. The production lifecycle already settles starts before stopping, so the unsettled-start case is a safety check for direct overlap, not a new scheduling policy.

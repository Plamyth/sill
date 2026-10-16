# Native text draft checks

The parent runs `python3 -B Tests/checks/native-text-draft/run.py ROOT OUTPUT` with absolute paths. OUTPUT must be outside ROOT. The runner emits `RESULT_JSON` and an isolated `result.json`. It compiles production `SessionLink`, the separate pure draft model, and the actual extracted StreamClient boundary against inert Network and SwiftUI adapters. It does not instantiate UIKit or send network traffic.

Run the existing controls and presentation suites as well. Their extractors and source lists include the new model. The controls suite retains its original `remote.py` and `mini.py` entry points. The presentation suite accepts `python3 -B Tests/checks/presentation-epoch/run.py ROOT OUTPUT`.

Runtime cases cover ticket ownership, cancellation before asynchronous enqueue, held and fenced per-message counts, peer/permit/catalog refusal, terminal callbacks and lock reentry, actual send/cancel races, foreground loss on a legacy host, route start, scope replacement, duplicate requests, weak client ownership, and frozen editor generations. Text checks exercise exact UTF8, Korean composition refusal, observed Dictation ambiguity, controls, newline separators, Character/byte/cluster bounds, and explicit recovery. UIKit hooks and project membership have static source contracts. The product SDK build remains a parent-owned gate.

Each mutant must match every anchor once, compile successfully, and exit with exactly its named runtime failure. A compiler error, timeout, or unrelated failure is not a kill. Failures retain bounded diagnostics in `RESULT_JSON` so the parent can preserve evidence after removing remote temporary output.

This suite cannot establish physical Dictation callback ordering, system Voice Control behavior, microphone state, text-field focus, CGEvent handling by a destination application, or host acceptance. A submitted ticket means only that its existing input message was handed to Network.send. No test text is persisted by the product.

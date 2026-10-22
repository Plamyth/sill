import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess

HERE = Path(__file__).resolve().parent
CLIENT = HERE.parents[1]


def block(text, marker):
    start = text.index(marker)
    opening = text.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]


source = (CLIENT / "StreamClient.swift").read_text()
markers = [
    "private enum StartupAutoConnection",
    "func armSavedMacAutoConnect()",
    "private func trySavedMacAutoConnect()",
    "private func dialUnconstrained(",
    "func disconnect()",
    "func connect(to mac:",
]
if "func fallBackFromStartupWired()" in source:
    markers.append("func fallBackFromStartupWired()")
if "func dialSavedAtStartup(" in source:
    markers.append("func dialSavedAtStartup(")
methods = "\n".join(block(source, marker) for marker in markers).replace("#if os(iOS)", "#if true")
fixture = (HERE / "Standins.swift").read_text().replace("// EXTRACTED_METHODS", methods)
remote = (CLIENT / "StreamClient+Remote.swift").read_text()
fixture = fixture.replace("// RECONNECT_TYPE", block(source, "struct Reconnect"))
dial = block(remote, "func dialSaved(")
entry = dial[:dial.index("        let candidates =")].replace("#if os(iOS)", "#if true")
fixture = fixture.replace("// DIAL_SAVED_ENTRY", entry + "\n        remoteDials.append(macID); reasons.append(why); remoteDial = 1\n    }")
extra = "\n".join(block(remote, marker) for marker in ["func remoteDialFailed(", "private func lostReconnect(", "func reconnectIfListed()"])
# 실제 재시도 메서드는 시계·소켓 대역만 공유한다.
at = fixture.index("    private enum StartupAutoConnection")
fixture = fixture[:at] + extra.replace("func reconnectIfListed()", "@discardableResult\n    func reconnectIfListed()") + "\n" + fixture[at:]
start = remote.index("        if homeSessionEnded(s, error: error, goodbye: goodbye?.reason) { return }")
end = remote.index("        // The automatic reconnect's own dial", start)
fixture = fixture.replace("// EXTRACTED_SESSION_END", remote[start:end].replace("#if os(iOS)", "#if true"))
fixture += (HERE / "scenarios.swift").read_text()
parser = argparse.ArgumentParser()
parser.add_argument('--output', required=True)
args = parser.parse_args()
out = Path(args.output)
if not out.is_absolute() or out.exists(): raise SystemExit('fresh routed output required')
out.mkdir()
root = CLIENT.parent
inputs = {'main.swift': fixture, 'DiscoveryPolicy.swift': (CLIENT / 'DiscoveryPolicy.swift').read_text()}
sha = lambda data: hashlib.sha256(data).hexdigest()
hashes = {name: sha(value.encode()) for name, value in inputs.items()}
payload = json.dumps({'sources': {name: base64.b64encode(value.encode()).decode() for name, value in inputs.items()}, 'hashes': hashes}).encode()
runner = (root / 'Tests/checks/extended-desktop/remote.py').read_text()
start = runner.index('    collision = subprocess.run(')
end = runner.index('    disk = subprocess.check_output(', start)
runner = runner[:start] + runner[end:]
runner = runner.replace("'-parse-as-library', ", '')
paths = [CLIENT/'StreamClient.swift', CLIENT/'StreamClient+Remote.swift', CLIENT/'DiscoveryPolicy.swift', *HERE.glob('*.swift'), HERE/'run.py']
before = {str(p.relative_to(root)): sha(p.read_bytes()) for p in paths}
p = subprocess.run(['/Users/ambrion/.local/bin/mini', 'heavy', '--cwd', '/private/tmp', '--', 'python3', '-B', '-c', runner], input=payload, capture_output=True, timeout=240, env=dict(os.environ, CODEX_THREAD_ID='01a13ace-e372-7ed1-9946-149df37ee1c3'))
log = (p.stdout + p.stderr).decode(errors='replace')
(out/'run.log').write_text(log)
records = [json.loads(line[12:]) for line in log.splitlines() if line.startswith('RESULT_JSON ')]
receipt = {'scope': 'actual startup, fallback, failure and bounded retry methods; deterministic clock and socket standins; Mini RAM independent check, not SDK/device/sourceguard acceptance', 'sourceHashes': before, 'sourceUnchanged': all(sha(p.read_bytes()) == before[str(p.relative_to(root))] for p in paths), 'transportHashMatched': 'INPUT_SHA256 '+sha(payload) in log, 'inputHashes': hashes, 'remote': records[-1] if records else None, 'exit': p.returncode}
(out/'result.json').write_text(json.dumps(receipt, indent=2)+'\n')
print(log)
print('RECEIPT '+str(out/'result.json'))
remote = receipt['remote'] or {}
verified = receipt['sourceUnchanged'] and receipt['transportHashMatched'] and all(remote.get(key) for key in ['inputHashesMatched', 'memoryInputUnchanged', 'childrenReaped', 'sourceRemoved'])
raise SystemExit(p.returncode or (0 if verified and remote.get('exitCode') == 0 else 2))

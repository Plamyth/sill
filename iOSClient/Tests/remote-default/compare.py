import hashlib
import json
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
CLIENT = HERE.parents[1]
AUDIT = CLIENT / ".audit"
failures = {}
for label, flags in [("baseline", ["--baseline"]), ("candidate", [])]:
    log = AUDIT / f"remote-default-{label}-policies.log"
    with log.open("w") as output:
        result = subprocess.run([sys.executable, str(HERE / "policies.py"), *flags], stdout=output, stderr=subprocess.STDOUT, timeout=600)
    text = log.read_text()
    if "error:" in text or "Traceback" in text or result.returncode not in [0, 1]:
        raise SystemExit(f"{label} did not run all suites; see {log}")
    failures[label] = [line for line in text.splitlines() if line.startswith("FAIL ")]
    print(f"{label}: {len(failures[label])} failed assertions", flush=True)
same = failures["baseline"] == failures["candidate"]
paths = [CLIENT / name for name in ["StreamClient.swift", "StreamClient+Remote.swift", "RemoteDialPolicy.swift"]]
record = {
    "baseHEAD": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=CLIENT.parent, text=True).strip(),
    "sameExistingFailures": same,
    "baselineFailedAssertions": len(failures["baseline"]),
    "candidateFailedAssertions": len(failures["candidate"]),
    "sourceSHA256": {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in paths},
    "scope": "Local pure client policy checks. No native iOS build, TLS handshake, device, signing, or installation.",
}
(AUDIT / "remote-default-comparison.json").write_text(json.dumps(record, indent=2) + "\n")
print(json.dumps(record, indent=2))
raise SystemExit(0 if same else 1)

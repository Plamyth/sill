import os
from pathlib import Path
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
CLIENT = HERE.parents[1]
ROOT = CLIENT.parent
CHECKS = ROOT / "Tests/checks"
cache = HERE / ".cache"
env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(cache))

baseline = "--baseline" in sys.argv
focused = "--focused" in sys.argv
failed = []
for name in (["startup-security"] if focused else ["policy", "home-device", "remote-rules"]):
    with tempfile.TemporaryDirectory(prefix="build-", dir=HERE) as folder:
        out = Path(folder)
        inputs = [CLIENT / "DiscoveryPolicy.swift"]
        tests = [] if focused else [CHECKS / name / "main.swift"]
        if name == "policy":
            tests.append(CHECKS / name / "home.swift")
        if name in ["remote-rules", "startup-security"]:
            inputs += [CLIENT / "RemoteDialPolicy.swift", CLIENT / "SavedMacs.swift"]
            inputs += sorted((ROOT / "Sources/StreamProtocol").glob("*.swift"))
            if focused:
                tests += [HERE / "trust.swift", HERE / "retirement.swift", HERE / "retirement-glue.swift"]
                (out / "main.swift").write_text('''import Foundation
var passes = 0, fails = 0
typealias R = RemoteDialPolicy
func check(_ name: String, _ ok: Bool) {
    if ok { passes += 1; print("PASS " + name) } else { fails += 1; print("FAIL " + name) }
}
startupTrustChecks()
retirementChecks()
print("\\(passes) passed, \\(fails) failed")
exit(fails == 0 ? 0 : 1)
''')
            else:
                tests.append(CHECKS / name / "home.swift")
        for path in inputs + tests:
            text = (subprocess.check_output(["git", "show", "HEAD:" + str(path.relative_to(ROOT))], cwd=ROOT, text=True)
                    if baseline and path in inputs else path.read_text())
            if path.name == "retirement-glue.swift":
                stream = (CLIENT / "StreamClient.swift").read_text()
                start = stream.index("    func retireOriginalCCREntryIfProven()")
                end = stream.index("\n    private func trySavedMacAutoConnect()", start)
                text = text.replace("// EXTRACTED_RETIREMENT", stream[start:end].replace("UserDefaults.standard", "RetirementDefaults.standard"))
            text = text.replace("import StreamProtocol\n", "")
            (out / path.name).write_text(text)
        subprocess.run(["swiftc", "-O", "-module-cache-path", str(cache),
                        *map(str, sorted(out.glob("*.swift"))), "-o", str(out / "check")],
                       check=True, env=env, timeout=180)
        print(f"SUITE {name}", flush=True)
        result = subprocess.run([str(out / "check")], timeout=60)
        if result.returncode:
            failed.append(name)
print(f"SUITES FAILED: {failed}", flush=True)
raise SystemExit(bool(failed))

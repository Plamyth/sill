"""합성 메모리 PCM 검사. 기기, 마이크, 엔진, 네트워크와 원음 파일을 사용하지 않는다."""
from pathlib import Path
import hashlib
import json
import subprocess
import sys
import shutil

root = Path(__file__).resolve().parents[3]
out = Path(sys.argv[1]).resolve()
out.mkdir(parents=True, exist_ok=True)
subprocess.run([
    "xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
    "-module-cache-path", str(out / "cache"),
    str(root / "iOSClient/NativeRealtimePCMCodec.swift"),
    str(Path(__file__).with_name("main.swift")), "-o", str(out / "check"),
], check=True)
args = [str(out / "check")]
if len(sys.argv) > 2:
    node = sys.argv[3] if len(sys.argv) > 3 else shutil.which("node")
    if not node or not Path(node).is_file():
        raise SystemExit("Core interop requires an existing Node executable path")
    args += [str(Path(__file__).with_name("core-interop.js")), str(Path(sys.argv[2]).resolve()), node]
subprocess.run(args, check=True)
paths = [root / "iOSClient/NativeRealtimePCMCodec.swift", Path(__file__).with_name("main.swift"),
         Path(__file__).with_name("core-interop.js"), Path(__file__)]
if len(sys.argv) > 2:
    paths.append(Path(sys.argv[2]).resolve())
print(json.dumps({"received_sha256": {str(p.relative_to(root) if p.is_relative_to(root) else p): hashlib.sha256(p.read_bytes()).hexdigest()
                                     for p in paths}}, sort_keys=True))

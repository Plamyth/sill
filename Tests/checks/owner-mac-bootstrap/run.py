import hashlib
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
paths = [root / "Sources/StreamProtocol" / name for name in
         ["RemoteIdentity.swift", "AddressParser.swift", "OwnerMacBootstrap.swift"]]
paths.append(Path(__file__).with_name("Checks.swift"))
before = {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}
with tempfile.TemporaryDirectory(prefix="ccr-owner-profile-") as scratch:
    binary = Path(scratch) / "checks"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", *map(str, paths), "-module-cache-path", str(Path(scratch) / "module-cache"), "-o", str(binary)],
                   check=True, timeout=180)
    subprocess.run([str(binary)], check=True, timeout=30)
assert all(hashlib.sha256(Path(name).read_bytes()).hexdigest() == digest for name, digest in before.items())
print("sourceUnchanged=true scratchRemoved=" + str(not Path(scratch).exists()).lower())

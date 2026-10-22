from pathlib import Path
import subprocess,tempfile
here=Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix="peer-transport-") as tmp:
 p=Path(tmp)
 subprocess.run(["python3",str(here/"run.py"),"--emit",str(p/"Checks.swift")],check=True)
 subprocess.run(["xcrun","swiftc","-swift-version","5",str(p/"Checks.swift"),"-o",str(p/"checks")],check=True)
 subprocess.run([str(p/"checks")],check=True)

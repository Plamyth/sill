from pathlib import Path
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix="ccr-toolbar-") as folder:
    out = Path(folder)
    subprocess.run(["swiftc", "-module-cache-path", str(out / "cache"),
                    str(HERE.parents[1] / "IPadToolbarVisibility.swift"), str(HERE / "main.swift"),
                    "-o", str(out / "check")], check=True, timeout=120)
    subprocess.run([str(out / "check")], check=True, timeout=10)

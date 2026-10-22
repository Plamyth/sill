import subprocess
for suite in ["host","topology"]:
 subprocess.run(["python3","Tests/checks/source-intent/run.py","--suite",suite],check=True)

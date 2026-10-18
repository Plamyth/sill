"""Source-only new-contract probe, optionally against an immutable baseline ref."""
import json, subprocess, sys
from pathlib import Path
root = Path(__file__).resolve().parents[3]
def read(name):
    return subprocess.check_output(["git", "show", sys.argv[1] + ":" + name], cwd=root, text=True) if len(sys.argv)>1 else (root/name).read_text()
adapter=read("iOSClient/StreamClient+DesiredAudio.swift")
model=read("iOSClient/IPadDesiredAudio.swift")
mic=read("iOSClient/StreamClient+Microphone.swift")
checks={
 "audio grants do not depend on displayed video or pointer control": not any(x in adapter+model for x in ["fullControl", "sawNotReady", "readDesiredAudioPresentation", "InputOverlayView"]),
 "foreground and OS authorization renew a bounded request cycle": all(x in model for x in ["observeForeground", "guard foreground != active", "permissionCycle", "observeMicrophoneAuthorization"]),
 "actual microphone begin and frame opening retain peer scope request grant revision gates": all(x in mic for x in ["desiredAudioPermits(.microphone)", "microphonePolicy.grantID == grant", "microphonePolicy.scope == scope", "desiredAudio.revision(for: .microphone) == revision"]),
 "unknown privacy still blocks both manual and automatic starts": "privacy == .protected" in model and "guard automatic else { return true }" not in model,
}
print(json.dumps({"evidence":"source-only contract probe, not runtime", "checks":checks},indent=2))
raise SystemExit(0 if all(checks.values()) else 1)

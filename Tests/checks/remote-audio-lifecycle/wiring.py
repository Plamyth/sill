#!/usr/bin/env python3
"""Check the real coordinator uses the tested lifecycle at each capture boundary.

Mutating one call site at a time must fail this check. The Swift harness in this
folder then runs the lifecycle itself with controlled capture continuations.
"""

import pathlib
import sys


def section(source: str, start: str, end: str) -> str:
    return source.split(start, 1)[1].split(end, 1)[0]


def wired(source: str) -> bool:
    try:
        stop = section(source, "private func stopRemoteAudioIfIdle()", "private func revokeRemoteAudio")
        revoke = section(source, "private func revokeRemoteAudio", "private func canEnableRemoteAudio")
        control = section(source, "private func controlRemoteAudio", "private func sendCatalog")
    except IndexError:
        return False
    return all((
        "remoteAudioLifecycle.scheduleStop" in stop,
        "!remoteAudioLifecycle.isStopping" in stop,
        "await self.remoteAudioCapture.stop()" in stop,
        "remoteAudioLifecycle.waitUntilIdle()" in revoke,
        "remoteAudioLifecycle.waitToStart" in control,
        "remoteAudioLifecycle.acquireStart" in control,
        "remoteAudioLifecycle.settleStart(start)" in control,
        control.count("remoteAudioLifecycle.isStopping") == 2,
        "remoteAudioStart = nil" not in control,
    ))


source = pathlib.Path(sys.argv[1]).read_text()
assert wired(source), "coordinator bypasses the tested capture lifecycle"
mutants = [
    "remoteAudioLifecycle.scheduleStop",
    "await self.remoteAudioCapture.stop()",
    "remoteAudioLifecycle.waitUntilIdle()",
    "remoteAudioLifecycle.waitToStart",
    "remoteAudioLifecycle.acquireStart",
    "remoteAudioLifecycle.settleStart(start)",
    "remoteAudioLifecycle.isStopping",
]
for marker in mutants:
    assert marker in source, marker
    assert not wired(source.replace(marker, "bypassedLifecycle", 1)), marker
print(f"remote audio coordinator wiring: {len(mutants)} of {len(mutants)} mutants caught")

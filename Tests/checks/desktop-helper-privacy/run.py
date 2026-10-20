#!/usr/bin/env python3
"""Run the production privacy lifecycle with inert capture and application adapters."""
import hashlib
import importlib.util
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('focus_checks', ROOT/'Tests/checks/host-input-focus-fence/run.py')
focus = importlib.util.module_from_spec(spec)
spec.loader.exec_module(focus)
paths = [ROOT/'Sources/SillHost/DesktopCapturePrivacy.swift', ROOT/'Sources/SillHost/WindowCatalog.swift',
         Path(__file__).with_name('Checks.swift'), ROOT/'Sources/SillHost/WindowCapture.swift',
         ROOT/'Sources/SillHost/StreamCoordinator.swift']
before = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
source = paths[0].read_text().replace('import AppKit\n', '').replace('import ScreenCaptureKit\n', '')
predicate = focus.function(paths[1].read_text(), 'nonisolated static func isPrivateApplication(')
fixture = paths[2].read_text().replace('// PREDICATE', predicate)
capture, coordinator = paths[3].read_text(), paths[4].read_text()
assert 'desktopDisplay: source == .desktop && !synthetic ? catalog.display : nil' in coordinator
assert 'prepared = try await privacy?.initialFilter()' in capture
assert capture.index('prepared = try await privacy?.initialFilter()') < capture.index('SCStream(filter: prepared?.0 ?? filter')
assert 'if let admission = current.1 { admission.deliver(deliver) }' in capture
assert 'guard current.0, type == .screen' in capture
assert 'privacy?.stop()' in capture
program = source + '\n' + fixture
runner = '''import hashlib,subprocess,sys
source=sys.stdin.buffer.read()
print('received_sha256='+hashlib.sha256(source).hexdigest(),flush=True)
result=subprocess.run(['/usr/bin/swift','-swift-version','5','-'],input=source,timeout=120)
del source
print('RAM input released; no source checkout',flush=True)
raise SystemExit(result.returncode)
'''
print('sent_sha256='+hashlib.sha256(program.encode()).hexdigest(),flush=True)
result = subprocess.run(['/Users/ambrion/.local/bin/mini','run','--cwd','/Users/sin-wonho','--','python3','-B','-c',runner],
                        input=program,text=True,timeout=180)
assert before == {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
print('source_hashes_unchanged='+str(before),flush=True)
raise SystemExit(result.returncode)

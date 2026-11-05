"""Pure policy and unmodified extracted client methods, with deterministic I/O stand-ins."""
from pathlib import Path
import ast, os, subprocess, tempfile
ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
parsed = ast.parse((ROOT/'iOSClient/Tests/remote-default/run.py').read_text())
ns = {}
exec(compile(ast.Module(body=[n for n in parsed.body if isinstance(n, ast.FunctionDef) and n.name == 'block'], type_ignores=[]), 'extractor', 'exec'), ns)
source = (ROOT/'iOSClient/StreamClient.swift').read_text()
markers = ['func ownerWiredBinding(', 'func ownerWiredValid(', 'func cancelOwnerWiredResolution(', 'private func ownerWiredKey(', 'func beginOwnerWired(', 'private func dialOwnerWiredOrTailnet(', 'func ownerWiredChanged()', 'private func moveProbed(', 'private func homeListProbed(', 'private func moveSaidGoodbye(']
methods = '\n'.join(ns['block'](source, m) for m in markers).replace('#if os(iOS)', '#if true').replace('private func ', 'func ')
# Execute the real startMove state handler, including its TLS-ready branch. Parameters and
# DNS/TLS I/O are test doubles; production callback and catalog admission branches are unchanged.
move = ns['block'](source, 'private func startMove(')
handler = ns['block'](move, 'c.stateUpdateHandler =')
methods += '\nfunc installActualMoveHandler(_ c: NWConnection) {\n let kind = MoveKind.fromRemote; let homeViewport: Data? = nil; var wasReady = false; let fallback: NWEndpoint? = nil; let givesUp = false\n' + handler + '\n}'
fixture = (HERE/'Standins.swift').read_text().replace('/* ACTUAL_METHODS */', methods) + '\n' + (HERE/'scenarios.swift').read_text()
with tempfile.TemporaryDirectory(prefix='owner-wired-') as tmp:
    out = Path(tmp); (out/'main.swift').write_text(fixture)
    subprocess.run(['swiftc', '-module-cache-path', str(out/'cache'), str(ROOT/'iOSClient/DiscoveryPolicy.swift'), str(ROOT/'iOSClient/OwnerWiredPolicy.swift'), str(out/'main.swift'), '-o', str(out/'checks')], check=True)
    subprocess.run([str(out/'checks')], check=True)

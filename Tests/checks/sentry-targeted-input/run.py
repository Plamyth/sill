import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser()
parser.add_argument('--archive', type=Path, required=True)
parser.add_argument('--label', required=True)
parser.add_argument('--suite', choices=['all', 'input', 'native', 'sentry', 'targeted', 'control', 'affected', 'local-auth-window'], default='all')
args = parser.parse_args()
archive = args.archive.resolve()
archive.mkdir(parents=True, exist_ok=True)
log, receipt = [archive / (args.label + suffix) for suffix in ['.log', '.json']]
if log.exists() or receipt.exists():
    raise SystemExit('기존 시도 영수증을 보존하고 대조하세요.')
paths = [p for folder in ['Sources', 'Tests/checks/sentry', 'Tests/checks/sentry-input-delivery',
         'Tests/checks/sentry-native-auth', 'Tests/checks/sentry-targeted-input', 'Tests/checks/local-auth-window-input']
         for p in (ROOT / folder).rglob('*') if p.is_file() and p.suffix in ['.swift', '.py']]
hashes = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}


def read(name):
    return (ROOT / name).read_text()


def block(text, marker):
    start = text.index(marker)
    end = start
    parentheses = 0
    while True:
        char = text[end]
        if char == '(':
            parentheses += 1
        elif char == ')':
            parentheses -= 1
        elif char == '{' and parentheses == 0:
            end += 1
            break
        end += 1
    depth = 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]


platform = read('Sources/SillHost/HostSentryPlatform.swift')
authentication_input_policy = read('Sources/SillHost/LocalAuthenticationInputPolicy.swift')
injector = read('Sources/SillHost/InputInjector.swift')
coordinator = read('Sources/SillHost/StreamCoordinator.swift')
protocol = '\n'.join(p.read_text() for p in sorted((ROOT / 'Sources/StreamProtocol').glob('*.swift')))
post = block(injector, 'private func post(_ event: CGEvent)')
assert post.count('event.post(tap: .cghidEventTap)') == 1
assert platform.count('event.postToPid(target.pid)') == 1
assert not re.search(r'ignoresMouseEvents\s*=\s*true', platform)
support = '\n'.join(read('Sources/SillHost/' + name + '.swift') for name in ['KeyStrokes', 'GestureChords']) + '''
final class PointerWatch { func sillMoved(to point: CGPoint) {} ; func sillMoved() {} }
final class Stats { static let shared = Stats(); func bump(_ name: String) {} }
'''
level = next(line.strip() for line in platform.splitlines() if 'private static let curtainLevel =' in line)
markers = ['private struct Curtain {', 'private var isProtected:', 'private func makeCurtain(',
           'private func updateCurtainText()', 'private func invalidate(', 'private func filter(']
input_program = read('Tests/checks/sentry-input-delivery/Main.swift').replace(
    '__PRODUCTION_PLATFORM__', level + '\n' + '\n'.join(block(platform, m) for m in markers))
input_program = input_program.replace('__PRODUCTION_POST__', post.replace('event.post(tap: .cghidEventTap)',
    'posted.append(event.copy()!)') + '\n' + block(injector, 'private static func isKeyboard('))
input_program = input_program.replace('static let remoteEventTag: Int64 = 0x435352',
    next(line.strip() for line in platform.splitlines() if 'static let remoteEventTag =' in line))
input_program = authentication_input_policy + '\n' + input_program
native = read('Tests/checks/sentry-native-auth/Main.swift').replace('__PRODUCTION__', re.sub(r'\bCGEvent\b', 'Event',
    '\n'.join(block(platform, m) for m in ['private var isProtected:', 'private func invalidate(', 'private func filter(',
        'private func updateCurtainText()', 'var reason: String?'])))
native = authentication_input_policy + '\n' + native
authentication_window = authentication_input_policy + '\n' + read('Tests/checks/local-auth-window-input/Main.swift').replace(
    '__PRODUCTION__', re.sub(r'\bCGEvent\b', 'Event', '\n'.join(block(platform, m) for m in [
        'private var isProtected:', 'private func invalidate(', 'private func filter(', 'private func filterAnnotated(', 'private func authenticationInputAllowed(',
        'private var inputTapsAreReady:', 'private func tapStopped(', 'private func observedReturnButton(',
        'var reason: String?', 'func localAuthenticationWillBegin('])))
authentication_window = authentication_window.replace('__PRODUCTION_OBSERVER__',
    platform[platform.index('    private static let authenticationExecutables ='):platform.index('    private static func processIdentity(')] + '\n' +
    '\n'.join(block(platform, m) for m in ['private static func verifiedAuthenticationOwner(',
        'private func refreshInputObservation(', 'private func isObservedAuthenticationWindow(', 'private func refreshRemoteTarget(', 'private func nextAuthenticationEventTag(']))
authentication_window = re.sub(r'\bCGEvent\b', 'Event', authentication_window)
assert 'audioPrivacy?.localAuthenticationWillBegin = { [weak platform] requestID in' in coordinator
assert 'platform?.localAuthenticationWillBegin(requestID)' in coordinator
assert 'self?.audioPrivacy?.localAuthenticationChallengeID' in coordinator
with tempfile.TemporaryDirectory(prefix='extraction-', dir=archive) as temporary:
    target = Path(temporary) / 'fixture'
    subprocess.run(['python3', '-B', str(ROOT / 'Tests/checks/sentry/emit-curtains.py'), '--output', str(target)], check=True)
    fixture = {p.name: p.read_text() for p in target.glob('*.swift')}
    extraction = json.loads((target / 'manifest.json').read_text())
sentry = authentication_input_policy + '\n' + '\n'.join([read('Sources/SillHost/SentryAdmission.swift'), read('Sources/SillHost/HostSentry.swift'),
    fixture['Main.swift'], fixture['CurtainChecks.swift'], fixture['CursorChecks.swift']])
actual = injector + '\n' + support
inert = actual.replace('event.post(tap: .cghidEventTap)', 'globalPosts.append(event.copy()!)')
inert = inert.replace('final class InputInjector {', '''final class InputInjector {
    var globalPosts: [CGEvent] = []
    var rejectedGlobalTypes = Set<CGEventType>()
    func testWatchdog() { scrollWentQuiet() }
''')
inert = inert.replace('globalPosts.append(event.copy()!)', 'if rejectedGlobalTypes.contains(event.type) { return false }; globalPosts.append(event.copy()!)')
inert = inert.replace(block(injector, 'private func pointerNow()'),
                      'private func pointerNow() -> CGPoint { lastPointerLocation }')
inert = inert.replace(block(injector, 'private func remindAboutAccessibilityIfNeeded()'),
                      'private func remindAboutAccessibilityIfNeeded() {}')
egress_markers = ['private struct PointerTarget {', 'private var isProtected:',
    'func prepareRelease(cleanup:', 'func prepareRemoteRelease(', 'var releaseVerified:', 'func release()', 'func protectedPointerEgress(', 'private func postProtectedPointer(', 'private func pointerTarget(']
egress = '\n'.join(block(platform, m) for m in egress_markers) + '\nprivate var pointerTargets: [Int: PointerTarget] = [:]\nprivate var scrollHandoff: PointerTarget?\n'
egress = egress.replace('event.postToPid(target.pid)', 'posted.append((target.pid, event.copy()!))')
egress = egress.replace('NSRunningApplication(processIdentifier: pid)', 'apps[pid]')
egress = egress.replace('NSWorkspace.shared.frontmostApplication', 'foreground')
tag = 'enum HostSentryPlatform { static let remoteEventTag: Int64 = 0x435352 }\n'
coord = read('Tests/checks/sentry-targeted-input/CoordinatorChecks.swift').replace('__PRODUCTION_COORDINATOR__',
    '\n'.join(block(coordinator, m) for m in ['private func preparePeerInteraction(', 'private func protectedPointerScope(']))
assert 'self.peerStreams[device] === lane' in coord
targeted = authentication_input_policy + '\n' + read('Sources/SillHost/SentryAdmission.swift') + '\n' + read('Sources/SillHost/HostSentry.swift') + '\n' + inert + '\n' + tag + read('Sources/SillHost/PeerInputQueue.swift') + '\n' + coord + '\n' + read('Tests/checks/sentry-targeted-input/Main.swift').replace('__PRODUCTION_EGRESS__', egress) + '\n' + read('Tests/checks/sentry-targeted-input/FollowupChecks.swift').replace('__PRODUCTION_RELEASE_BARRIER__', block(coordinator, 'prepareRelease: { [weak self] in').removeprefix('prepareRelease: '))
assert not any(token in targeted + input_program for token in ['event.post(', '.postToPid(', '__PRODUCTION_'])
assert coordinator.count('protectedScope: protectedPointerScope(device: device, epoch: epoch)') == 1
assert coordinator.count('protectedScope: self.protectedPointerScope(device: id, epoch: epoch, isCurrent: { !turn.cancelled })') == 1
assert 'platform?.protectedPointerEgress(event, scope: scope) == true' in coordinator
filter_body = block(platform, 'private func filter(')
assert not any(token in filter_body for token in ['CGWindowList', 'SecCode', 'AXUIElement', 'postToPid', 'NSWorkspace', 'environmentIsUsable', 'visibleReturnButton'])
control = read('Tests/checks/sentry-targeted-input/ControlChecks.swift').replace('__PRODUCTION_CONTROL__',
    '\n'.join(block(coordinator, marker) for marker in ['private func activateSentry(', 'private func grantSentryControl(',
        'private func currentSentryOwner(', 'private func handleSentryControl(']))
control = read('Sources/SillHost/SentryAdmission.swift') + '\n' + read('Sources/SillHost/HostSentry.swift') + '\n' + control
payload = {'protocol': protocol, 'control': control, 'local-auth-window': authentication_window, 'platformSDK': authentication_input_policy + '\n' + platform + '\n' + actual + '''
enum StreamCoordinator { static func isSillVirtualDisplay(_ id: CGDirectDisplayID) -> Bool { false } }
''', 'input': input_program, 'native': native, 'panel': authentication_input_policy + '\n' + fixture['NativePanelChecks.swift'], 'sentry': sentry, 'targeted': targeted, 'suites': (['input','panel','sentry','targeted'] if args.suite=='affected' else ['panel','sentry'] if args.suite=='sentry' else [args.suite] if args.suite!='all' else ['input','native','panel','sentry','targeted','local-auth-window'])}
blob = json.dumps(payload, ensure_ascii=False, separators=(',', ':')).encode()
remote = r'''
import hashlib,json,pathlib,subprocess,sys,tempfile
blob=sys.stdin.buffer.read()
payload=json.loads(blob)
print('received_sha256='+hashlib.sha256(blob).hexdigest(),flush=True)
records=[]; finalCode=0
with tempfile.TemporaryDirectory(prefix='ccr-targeted-binaries-') as temporary:
 out=pathlib.Path(temporary)
 sdk=subprocess.check_output(['/usr/bin/xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip()
 compiler=subprocess.check_output(['/usr/bin/xcrun','--find','swiftc'],text=True).strip()
 print(subprocess.check_output([compiler,'--version'],text=True),flush=True)
 print('SDK='+sdk,flush=True)
 flags=[compiler,'-swift-version','5','-parse-as-library','-whole-module-optimization','-package-name','Sill','-sdk',sdk,'-target','arm64-apple-macosx14.0','-module-cache-path',str(out/'cache')]
 def compile(name,source,extra):
  result=subprocess.run(flags+extra+['-'],input=source.encode(),stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=180)
  print(result.stdout.decode(errors='replace'),end='',flush=True)
  records.append({'name':name,'compileExit':result.returncode,'inputSHA256':hashlib.sha256(source.encode()).hexdigest()})
  return result.returncode==0
 module=out/'StreamProtocol.swiftmodule'; obj=out/'StreamProtocol.o'
 if not compile('protocol-module',payload['protocol'],['-emit-module','-module-name','StreamProtocol','-emit-module-path',str(module)]): raise SystemExit(2)
 if not compile('protocol-object',payload['protocol'],['-emit-object','-module-name','StreamProtocol','-o',str(obj)]): raise SystemExit(2)
 if not compile('platform-injector-SDK',payload['platformSDK'],['-I',str(out),'-typecheck']): raise SystemExit(2)
 for name in payload['suites']:
  binary=out/name
  if not compile(name,payload[name],['-I',str(out),str(obj),'-o',str(binary)]):
   finalCode=max(finalCode,2); continue
  records[-1]['cases']=[]
  cases=[('curtains',['--curtains']),('refresh',['--refresh']),('sentry',[]),('cursor',['--cursor'])] if name=='sentry' else [(name,[])]
  for case,args in cases:
   result=subprocess.run([str(binary)]+args,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=30)
   output=result.stdout.decode(errors='replace'); print(output,end='',flush=True)
   records[-1]['cases'].append({'name':case,'exitCode':result.returncode,'passedAssertions':sum(line.startswith('PASS ') for line in output.splitlines()),'failures':[line for line in output.splitlines() if line.startswith('FAIL ')]})
   finalCode=max(finalCode,result.returncode)
 del payload,blob
print('REMOTE_RESULT '+json.dumps({'records':records,'temporaryFilesRemoved':not out.exists(),'sourceFilesWritten':0,'actualOSAuthentication':0,'actualEventPosts':0,'visibleWindows':0,'hostLaunches':0,'HALWrites':0,'serviceWrites':0}),flush=True)
raise SystemExit(finalCode)
'''
with log.open('xb') as output:
    output.write(('sent_sha256=' + hashlib.sha256(blob).hexdigest() + '\n').encode()); output.flush()
    result = subprocess.run(['/Users/ambrion/.local/bin/mini', 'run', '--cwd', '/Users/sin-wonho', '--',
        'python3', '-B', '-c', remote], input=blob, stdout=output, stderr=subprocess.STDOUT, timeout=900)
lines = log.read_text().splitlines()
summary = next((json.loads(line.removeprefix('REMOTE_RESULT ')) for line in lines if line.startswith('REMOTE_RESULT ')), None)
record = {'sourceCommit': subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
    'sourceTree': subprocess.check_output(['git','rev-parse','HEAD^{tree}'],cwd=ROOT,text=True).strip(),
    'sourceSHA256': hashes, 'sourceUnchanged': all(hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==sha for name,sha in hashes.items()),
    'exitCode': result.returncode, 'sentSHA256': hashlib.sha256(blob).hexdigest(),
    'receivedSHA256': next((line.split('=',1)[1] for line in lines if line.startswith('received_sha256=')),None),
    'programSHA256': {name: hashlib.sha256(source.encode()).hexdigest() for name,source in payload.items() if isinstance(source,str)},
    'extraction': extraction, 'remote': summary,
    'scope': 'exact source SDK/inert validation; Mini memory-only source; no source-guard migration acceptance; no physical input or native authentication acceptance'}
receipt.write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({k:record[k] for k in ['exitCode','sentSHA256','receivedSHA256','sourceUnchanged','remote']},ensure_ascii=False))
raise SystemExit(result.returncode if record['sourceUnchanged'] else 2)

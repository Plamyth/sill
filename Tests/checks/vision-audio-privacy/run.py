"""Pure intent and shared authority models plus actual extracted store with inert audio clients. No capture, device, engine, network, or OS permission effects."""
from pathlib import Path
import json
import hashlib
import subprocess
import sys

root, output = [Path(value).resolve() for value in sys.argv[1:3]]
if output == root or root in output.parents:
    raise RuntimeError('isolated output required')
output.mkdir(parents=True, exist_ok=True)
exe = output / 'vision-audio-privacy'
command = ['/usr/bin/xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', str(output / 'cache'),
           str(root / 'visionOSClient/VisionRemoteAudioIntent.swift'),
           str(root / 'visionOSClient/VisionRemoteAudioAuthority.swift'),
           str(root / 'Tests/checks/vision-audio-privacy/authority.swift'),
           str(root / 'Tests/checks/vision-audio-privacy/main.swift'), '-o', str(exe)]
source = (root / 'visionOSClient/VisionRemoteAudioAuthority.swift').read_text()
store = source[source.index('final class VisionRemoteAudioStore {'):source.rindex('\n#endif')]
(output / 'Store.swift').write_text('import Foundation\n' + store)
client = (root / 'iOSClient/StreamClient.swift').read_text()
start = client.index('    func receiveVisionAudioCatalogAcknowledgement(')
end = client.index('    func updateVisionMacAudioRoutes(', start)
transport = client[start:end]
# Bind the production singleton call to this fixture's isolated store; method bodies are otherwise unchanged.
transport = transport.replace('VisionRemoteAudioStore.shared', 'store')
(output / 'CatalogTransport.swift').write_text('import Foundation\nextension StreamClient {\n' + transport + '}\n')
(output / 'main.swift').write_bytes((root / 'Tests/checks/vision-audio-privacy/adapter-main.swift').read_bytes())
adapter = ['/usr/bin/xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', str(output / 'cache'),
           str(root / 'visionOSClient/VisionRemoteAudioIntent.swift'),
           str(root / 'visionOSClient/VisionRemoteAudioAuthority.swift'), str(output / 'Store.swift'),
           str(root / 'Tests/checks/vision-audio-privacy/adapter.swift'), str(output / 'CatalogTransport.swift'),
           *[str(root / 'Sources/StreamProtocol' / name) for name in
             ['StreamMessage.swift', 'Switcher.swift', 'AudioPrivacy.swift', 'AudioRouting.swift']], str(output / 'main.swift'),
           '-o', str(output / 'adapter')]
server = (root / 'Sources/SillHost/StreamServer.swift').read_text()
start = server.index('    func sendMicrophoneCatalog(')
end = server.index('    func sendMicrophone(', start)
catalog_send = server[start:end]
coordinator = (root / 'Sources/SillHost/StreamCoordinator.swift').read_text()
query = coordinator[coordinator.index('        case .fetchCatalog:'):coordinator.index('        case .selectSource:')]
has_fallback = 'fallback: StreamMessage? = nil' in catalog_send
if has_fallback:
    if 'grant: grant, fallback: fallback)' not in query:
        raise RuntimeError('query must supply the capability-free ACK')
    start = query.index('                var fallbackList = list')
    end = query.index('                server.sendMicrophoneCatalog(', start)
    fallback_body = query[start:end]
else:
    fallback_body = 'var fallback = response\n'
fallback_function = ('func queryFallback(_ list: WindowList, _ response: StreamMessage) -> StreamMessage {\n'
                     + fallback_body + '\nreturn fallback\n}\n')
catalog_main = (root / 'Tests/checks/vision-audio-privacy/catalog-server.swift').read_text()
catalog_dir = output / 'catalog-server'
catalog_dir.mkdir(exist_ok=True)
(catalog_dir / 'main.swift').write_text(catalog_main + '\nextension StreamServer {\n' + catalog_send + '}\n' + fallback_function)
catalog_adapter = ['/usr/bin/xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', str(output / 'cache'),
                   *(['-D', 'CATALOG_QUERY_FALLBACK'] if has_fallback else []),
                   *[str(root / 'Sources/StreamProtocol' / name) for name in
                     ['StreamMessage.swift', 'Switcher.swift', 'AudioPrivacy.swift', 'AudioRouting.swift', 'MicrophoneUplink.swift']],
                   str(catalog_dir / 'main.swift'), '-o', str(catalog_dir / 'adapter')]
result = {'scope': __doc__, 'commands': [], 'exitCode': 1,
          'catalogSendSHA256': hashlib.sha256(catalog_send.encode()).hexdigest(),
          'catalogFallbackSHA256': hashlib.sha256(fallback_body.encode()).hexdigest(),
          'catalogTransportSHA256': hashlib.sha256(transport.encode()).hexdigest(),
          'storeSHA256': hashlib.sha256(store.encode()).hexdigest(),
          'adapterBoundary': 'Actual shared store copied verbatim. Inert StreamClient, player, microphone and hardware cleanup readback; no native graph, transport, OS permission or UI acceptance.'}
for label, args in [('compile', command), ('policy', [str(exe)]),
                    ('adapter-compile', adapter), ('adapter', [str(output / 'adapter')]),
                    ('catalog-server-compile', catalog_adapter), ('catalog-server', [str(catalog_dir / 'adapter')])]:
    run = subprocess.run(args, capture_output=True, text=True, timeout=90)
    (output / (label + '.log')).write_text(run.stdout + run.stderr)
    result['commands'].append({'label': label, 'exitCode': run.returncode})
    if run.returncode:
        break
else:
    result['exitCode'] = 0
(output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result))
sys.exit(result['exitCode'])

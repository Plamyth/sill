"""Extract the production draft model and client boundary using the prior input fixture."""
import hashlib
import importlib.util
import sys
from pathlib import Path


def fixture(root):
    root = Path(root).resolve()
    sys.path.insert(0, str(root / 'Tests/checks'))
    path = root / 'Tests/checks/vision-input-controls/extract.py'
    spec = importlib.util.spec_from_file_location('draft_prior', path)
    prior = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(prior)
    prior.ROOT = root
    files, manifest = prior.fixture()
    files = {name: source for name, source in files.items() if not name.startswith('mutants/')}
    files['main.swift'] = (root / 'Tests/checks/native-text-draft/main.swift').read_text()
    network = files['Network.swift']
    anchor = '    public enum SendCompletion'
    assert network.count(anchor) == 1
    network = network.replace(anchor, '    public var onSend: (() -> Void)?\n' + anchor, 1)
    anchor = '        lock.lock()\n        if let content'
    assert network.count(anchor) == 1
    files['Network.swift'] = network.replace(anchor, '        onSend?()\n' + anchor, 1)
    stream = (root / 'iOSClient/StreamClient.swift').read_text()
    active = prior.block(stream, '@Published var active: StreamSource =')
    active_vision = prior.select_platform(active, vision=True)
    start = active_vision.index('            if oldValue != active')
    observer = active_vision[start:active_vision.index('\n', start)]
    anchor = '    var active = StreamSource.desktop'
    assert files['Client.swift'].count(anchor) == 1
    files['Client.swift'] = files['Client.swift'].replace(anchor, anchor + ' {\n        didSet {\n' + observer + '\n        }\n    }', 1)
    manifest['activeObserver'] = hashlib.sha256(observer.encode()).hexdigest()
    workspace = (root / 'visionOSClient/SillVisionApp.swift').read_text()
    scope = prior.block(workspace, '.onChange(of: client.visionTextScope)')
    scope = scope[scope.index('{ _, _ in') + len('{ _, _ in'): -1]
    clear = prior.block(workspace, 'private func clearDraft()').replace('private ', '', 1)
    files['DraftWorkspace.swift'] = '''import Foundation
final class DraftWorkspace {
    let client: StreamClient
    var textDraft: VisionTextDraft<StreamClient.VisionTextTarget>?
    var draftShown = true
    init(_ client: StreamClient) { self.client = client }
    func updateInputAdmission() {}
    func scopeChanged() {
''' + scope + '\n    }\n' + clear + '\n}\n'
    manifest['draftScopeObserver'] = hashlib.sha256(scope.encode()).hexdigest()
    manifest['clearDraft'] = hashlib.sha256(clear.encode()).hexdigest()
    for name in ['iOSClient/SessionLink.swift', 'visionOSClient/VisionTextDraft.swift']:
        manifest[name] = hashlib.sha256(files[name].encode()).hexdigest()
    return files, manifest

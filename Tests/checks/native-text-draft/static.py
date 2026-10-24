"""Parent-only source contracts for the UIKit adapter and project membership."""
import ast
import hashlib
import plistlib
import sys
from pathlib import Path


def contracts(root):
    root = Path(root)
    editor = (root / 'visionOSClient/VisionDraftEditor.swift').read_text()
    workspace = (root / 'visionOSClient/SillVisionApp.swift').read_text()
    model = (root / 'visionOSClient/VisionTextDraft.swift').read_text()
    results = {}

    def check(name, passed):
        results[name] = bool(passed)
        if not passed:
            raise AssertionError(name)

    for hook in ['insertText(text)', 'setMarkedText(markedText, selectedRange: selectedRange)',
                 'unmarkText()', 'insertDictationResult(dictationResult)', 'dictationRecordingDidEnd()',
                 'dictationRecognitionFailed()', 'insertDictationResultPlaceholder',
                 'removeDictationResultPlaceholder(placeholder, willInsertResult: willInsertResult)']:
        check('UIKit super preserves ' + hook, 'super.' + hook in editor)
    check('UIKit live text has one owner', 'view.text = seed' in editor and 'view.text =' not in editor[editor.index('func updateUIView'):])
    check('review resamples actual editor', 'let observation = editor.sample()' in editor and 'draft?.review(observation)' in editor)
    check('no forced composition completion in review', 'editor.view?.unmarkText' not in editor)
    check('adapter observes composition and native delegate', 'markedTextRange != nil' in editor and 'textViewDidChangeSelection' in editor)
    check('draft editor cannot forward remote keys', 'sendInput' not in editor and 'InputOverlay' not in editor)
    check('no capture engine or timer inference', all(word not in editor + model for word in ['AVAudioEngine', 'SFSpeechRecognizer', 'requestRecordPermission', 'asyncAfter', 'Timer(']))
    check('underlying pointer surface disabled', '.allowsHitTesting(!draftShown)' in workspace)
    check('underlying controls disabled', '.disabled(!input.canSend || draftShown)' in workspace)
    admission = workspace[workspace.index('private var inputAllowed:'):workspace.index('private var macAudioModalShown:')]
    check('input admission excludes draft', '!inputSuspended' in admission and '!draftShown' in admission)
    opening = workspace[workspace.index('private func openDraft()'):workspace.index('private func clearDraft()')]
    check('original input owner releases before target capture', opening.index('releaseInput()') < opening.index('captureVisionTextTarget()'))
    check('original keyboard resigns before target capture', opening.index('resignFirstResponder') < opening.index('captureVisionTextTarget()'))
    check('draft dismissal never restores keyboard automatically', 'toggleKeyboard' not in workspace[workspace.index('private func clearDraft()'):])
    check('background clears draft explicitly', 'if value != .active { clearDraft(); releaseInput() }' in workspace)
    project = plistlib.loads((root / 'SillVision.xcodeproj/project.pbxproj').read_bytes())['objects']
    for filename in ['VisionTextDraft', 'VisionDraftEditor']:
        path = 'visionOSClient/' + filename + '.swift'
        ref = hashlib.sha1(path.encode()).hexdigest().upper()[:24]
        build = hashlib.sha1((path + '.build').encode()).hexdigest().upper()[:24]
        check(filename + ' matches generator file identity', project[ref]['path'] == path and project[build]['fileRef'] == ref)
        check(filename + ' belongs to Vision build', any(item['isa'] == 'PBXSourcesBuildPhase' and build in item['files'] for item in project.values()))
    for path in (root / 'Tests/checks/native-text-draft').glob('*.py'):
        ast.parse(path.read_text(), filename=str(path))
    return results


if __name__ == '__main__':
    import json
    print(json.dumps(contracts(Path(sys.argv[1]).resolve()), indent=2))

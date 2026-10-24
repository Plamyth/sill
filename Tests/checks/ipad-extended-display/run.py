from pathlib import Path
import subprocess
import sys


def block(source, marker):
    start = source.index(marker)
    end = source.index("{", start) + 1
    depth = 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


root = Path(__file__).resolve().parents[3]
out = Path(sys.argv[1]).resolve()
out.mkdir(parents=True, exist_ok=True)
screen = (root / "iOSClient/StreamScreen.swift").read_text()
portrait = (root / "iOSClient/PortraitStreamScreen.swift").read_text()
button = block(screen, "struct IPadExtendedDisplayButton: View")
assert 'accessibilityLabel: "iPad 확장 화면", action: selectExtendedDisplay' in button
assert '.accessibilityIdentifier("iPadExtendedDisplayButton")' in button
assert '.disabled(candidate == nil)' in button
assert 'Text("iPad 확장 화면")' in button
assert '.lineLimit(2)' in button
landscape = block(screen, "private struct TopBar: View")
vertical = block(portrait, "private func windowBar(")
for bar in [landscape, vertical]:
    assert 'IPadExtendedDisplayButton(client: client,' in bar
assert 'MacDisplayChooser(client: client,' in landscape
assert 'desktopButton(width: layout.buttonWidth)' in vertical
assert 'IPadExtendedDisplayButton' not in block(portrait, 'private func phoneRow1(')

standins = '''import Foundation
struct DisplayInfo: Equatable {
    var id: UInt32
    var name: String
    var width: Int = 1920
    var height: Int = 1080
    var isMain: Bool = false
    var role: String? = nil
}
enum StreamSource { case none, desktop, window }
final class ClientFixture {
    var displays: [DisplayInfo] = []
    var displaySelectionReady = true
    var active = StreamSource.none
    var activeDisplayID: UInt32?
    var submitted: [DisplayInfo] = []
    func selectDisplay(_ display: DisplayInfo) { submitted.append(display) }
}
'''
members = [block(button, marker).replace("private ", "", 1) for marker in [
    "private var candidate:", "private var selected:", "private func selectExtendedDisplay()"
]]
fixture = standins + block(screen, "enum IPadExtendedDisplaySelection {")
fixture += '\nstruct ButtonFixture {\nlet client: ClientFixture\n' + '\n'.join(members) + '\n}\n'
(out / "Fixture.swift").write_text(fixture)
subprocess.run([sys.executable, "-B", str(root / "Tests/checks/ipad-test-destinations/layout.py"),
                str(out / "Layout.swift")], check=True)
subprocess.run(["/usr/bin/swiftc", "-module-cache-path", str(out / "cache"),
                str(out / "Fixture.swift"), str(out / "Layout.swift"),
                str(Path(__file__).with_name("main.swift")), "-o", str(out / "check")], check=True)
subprocess.run([str(out / "check")], check=True)
print("버튼 연결·식별자·기존 모니터 선택 유지 정적 검사를 통과했습니다.")

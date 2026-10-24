from pathlib import Path
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
screen = (root / "iOSClient/StreamScreen.swift").read_text()
portrait = (root / "iOSClient/PortraitStreamScreen.swift").read_text()
menus = (root / "iOSClient/MacMenuButton.swift").read_text()
assert "IPadToolbarLayout(width: width - 2 * bar.padding, baseButtons: isPad ? 6 : 5," in screen
assert "IPadToolbarLayout(width: width, baseButtons: isPad ? 5 : 4," in portrait
assert "menusFit: layout.menusInline, workspaceInline: layout.workspaceInline" in screen
assert "if workspaceInline {" in screen and "if layout.workspaceInline {" in portrait
assert "if UIDevice.current.userInterfaceIdiom == .pad {" in block(screen, "private struct TopBar: View")
assert "if UIDevice.current.userInterfaceIdiom == .pad {" in block(portrait, "private func windowBar(")
assert "IPadWorkspaceMenu(" in block(screen, "private struct TopBar: View")
assert "IPadWorkspaceMenu(" in block(portrait, "private func windowBar(")
assert "IPadWorkspaceMenuTrigger(" in block(screen, "struct IPadWorkspaceMenu: View")
assert "workspaceMenuOpen ||" in block(screen, "private var toolbarPinned:")
assert "onOpenChange: workspaceMenuChanged" in block(screen, "private struct TopBar: View")
assert "onOpenChange: workspaceMenuChanged" in block(portrait, "private func windowBar(")
assert screen.count("workspaceMenuChanged: { workspaceMenuOpen = $0 }") == 2
assert "MacMenuTriggerButton" in block(screen, "private struct IPadWorkspaceMenuTrigger:")
assert 'UIAction(title: "iPad 앱 업데이트"' in block(screen, "private struct IPadWorkspaceMenuTrigger:")
assert "openAppUpdate: openAppUpdate" in block(screen, "struct IPadWorkspaceMenu: View")
content = (root / "iOSClient/ContentView.swift").read_text()
assert 'Button("iPad 앱 업데이트"' in content and "if !client.connected {" in content
assert '.environment(\\.openIPadAppUpdate, { appUpdatePresented = true })' in content
types = [block(screen, "struct IPadToolbarLayout {"), block(screen, "struct BarMetrics {")]
types.append(block(portrait, "struct PortraitMetrics {").split("    static let phone = PortraitMetrics(")[0] + "}")
types.append("struct MacMenuButton {" + block(menus, "static func fits(") + "}")
checks = r'''
func checkToolbarBounds() {
    func verify(width: CGFloat, padding: CGFloat, base: Int, button: CGFloat, height: CGFloat,
                gap: CGFloat, thumb: CGFloat, workspace: Bool, menus: Bool) {
        let available = width - 2 * padding
        for hasMenus in [false, true] {
            let layout = IPadToolbarLayout(width: available, baseButtons: base,
                                          buttonWidth: button, gap: gap, thumbWidth: thumb, isPad: true)
            precondition(layout.workspaceInline == workspace, "Wrong workspace placement at \(width) pt")
            precondition(layout.menusInline == menus, "Wrong menu placement at \(width) pt")
            let count = base + (layout.workspaceInline ? 2 : 0) + (hasMenus && layout.menusInline ? 1 : 0)
            let controls = CGFloat(count) * (layout.buttonWidth + gap)
            precondition(controls <= available, "Controls overflow at \(width) pt")
            precondition(layout.buttonWidth >= 44 && height >= 44, "Touch target shrank")
            if layout.workspaceInline || hasMenus && layout.menusInline {
                precondition(available - controls >= thumb + 16, "Inline controls displaced the thumbnail")
            }
        }
    }
    let p = PortraitMetrics.compact
    for width: CGFloat in [320, 400, 500] {
        verify(width: width, padding: p.padSide, base: 5, button: p.buttonWidth,
               height: p.buttonHeight, gap: 12, thumb: p.thumbWidth, workspace: false, menus: false)
    }
    let l = BarMetrics.compact
    verify(width: 500, padding: l.padding, base: 6, button: l.buttonWidth,
           height: l.buttonHeight, gap: l.gap, thumb: l.thumbWidth, workspace: false, menus: false)
    let regularPortrait = PortraitMetrics.regular
    verify(width: 710, padding: regularPortrait.padSide, base: 5, button: regularPortrait.buttonWidth,
           height: regularPortrait.buttonHeight, gap: 12, thumb: regularPortrait.thumbWidth, workspace: true, menus: false)
    let regularLandscape = BarMetrics.regular
    verify(width: 1024, padding: regularLandscape.padding, base: 6, button: regularLandscape.buttonWidth,
           height: regularLandscape.buttonHeight, gap: regularLandscape.gap, thumb: regularLandscape.thumbWidth,
           workspace: true, menus: true)
    for base in [5, 6] {
        let threshold = CGFloat(base + 2) * (l.buttonWidth + l.gap) + l.thumbWidth + 16
        for delta: CGFloat in [-1, 0, 1] {
            let layout = IPadToolbarLayout(width: threshold + delta, baseButtons: base,
                                          buttonWidth: l.buttonWidth, gap: l.gap, thumbWidth: l.thumbWidth, isPad: true)
            precondition(layout.workspaceInline == (delta >= 0), "Workspace fit boundary is wrong")
        }
        let phone = IPadToolbarLayout(width: 2000, baseButtons: base, buttonWidth: l.buttonWidth,
                                     gap: l.gap, thumbWidth: l.thumbWidth, isPad: false)
        precondition(!phone.workspaceInline, "iPad workspace leaked into phone toolbar")
        precondition(phone.buttonWidth == l.buttonWidth, "Phone button width changed")
    }
    print("Toolbar bounds passed for 320/400/500 pt portrait, 500 pt landscape, regular widths and fit boundaries")
}
'''
Path(sys.argv[1]).write_text("import Foundation\n" + "\n".join(types) + checks)

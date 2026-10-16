import Foundation

enum VisionRemoteKey: UInt16, CaseIterable, Identifiable {
    case tab = 0x2B, escape = 0x29, backspace = 0x2A, forwardDelete = 0x4C
    case left = 0x50, up = 0x52, down = 0x51, right = 0x4F
    case home = 0x4A, end = 0x4D, pageUp = 0x4B, pageDown = 0x4E
    case space = 0x2C, enter = 0x28
    case f1 = 0x3A, f2 = 0x3B, f3 = 0x3C, f4 = 0x3D, f5 = 0x3E, f6 = 0x3F
    case f7 = 0x40, f8 = 0x41, f9 = 0x42, f10 = 0x43, f11 = 0x44, f12 = 0x45

    var id: UInt16 { rawValue }
    var isFunction: Bool { (0x3A...0x45).contains(rawValue) }

    var title: String {
        switch self {
        case .tab: return "Tab"
        case .escape: return "Esc"
        case .backspace: return "⌫"
        case .forwardDelete: return "⌦"
        case .left: return "←"
        case .up: return "↑"
        case .down: return "↓"
        case .right: return "→"
        case .home: return "Home"
        case .end: return "End"
        case .pageUp: return "Page↑"
        case .pageDown: return "Page↓"
        case .space: return "공백"
        case .enter: return "Return"
        case .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12:
            return "F\(rawValue - 0x3A + 1)"
        }
    }

    var accessibilityName: String {
        switch self {
        case .backspace: return "뒤로 삭제"
        case .forwardDelete: return "앞으로 삭제"
        case .left: return "왼쪽 화살표"
        case .up: return "위쪽 화살표"
        case .down: return "아래쪽 화살표"
        case .right: return "오른쪽 화살표"
        default: return title
        }
    }
}

enum VisionModifier: CaseIterable, Identifiable {
    case command, option, control, shift
    var id: Self { self }
    var flag: KeyModifiers {
        switch self {
        case .command: return .command
        case .option: return .option
        case .control: return .control
        case .shift: return .shift
        }
    }
    var title: String {
        switch self {
        case .command: return "⌘"
        case .option: return "⌥"
        case .control: return "⌃"
        case .shift: return "⇧"
        }
    }
    var name: String {
        switch self {
        case .command: return "Command"
        case .option: return "Option"
        case .control: return "Control"
        case .shift: return "Shift"
        }
    }
}

enum VisionShortcut: CaseIterable, Identifiable {
    case selectAll, copy, paste, cut, undo, redo, save, find, switchApp, spotlight
    var id: Self { self }
    var desktopOnly: Bool { self == .switchApp || self == .spotlight }
    var title: String {
        switch self {
        case .selectAll: return "전체 선택"
        case .copy: return "복사"
        case .paste: return "붙여넣기"
        case .cut: return "잘라내기"
        case .undo: return "실행 취소"
        case .redo: return "다시 실행"
        case .save: return "저장"
        case .find: return "찾기"
        case .switchApp: return "앱 전환"
        case .spotlight: return "Spotlight"
        }
    }
    var keys: (UInt16, KeyModifiers) {
        switch self {
        case .selectAll: return (0x04, .command)
        case .copy: return (0x06, .command)
        case .paste: return (0x19, .command)
        case .cut: return (0x1B, .command)
        case .undo: return (0x1D, .command)
        case .redo: return (0x1D, [.command, .shift])
        case .save: return (0x16, .command)
        case .find: return (0x09, .command)
        case .switchApp: return (0x2B, .command)
        case .spotlight: return (0x2C, .command)
        }
    }
}

import SwiftUI

struct VisionKeyPalette: View {
    @ObservedObject var input: VisionInputSession
    let desktop: Bool
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 16) {
            Text("Mac 키와 단축키").font(.headline)
            HStack {
                ForEach(VisionModifier.allCases) { modifier in
                    Button(modifier.title) { input.toggle(modifier) }
                        .frame(minWidth: 60, minHeight: 60)
                        .tint(input.latched.contains(modifier.flag) ? .blue : .gray)
                        .accessibilityLabel(modifier.name)
                        .accessibilityValue(input.latched.contains(modifier.flag) ? "다음 입력에 적용" : "꺼짐")
                }
            }
            Text("수정키는 다음 키·클릭·드래그에 한 번 적용됩니다.").font(.caption)
            Picker("키 종류", selection: $tab) {
                Text("탐색").tag(0)
                Text("단축키").tag(1)
                Text("F1–F12").tag(2)
            }.pickerStyle(.segmented)
            if tab == 1 {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3)) {
                    ForEach(VisionShortcut.allCases) { shortcut in
                        Button(shortcut.title) { input.perform(shortcut) }
                            .frame(maxWidth: .infinity, minHeight: 60)
                            .disabled(shortcut.desktopOnly && !desktop)
                    }
                }
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4)) {
                    ForEach(VisionRemoteKey.allCases.filter { $0.isFunction == (tab == 2) }) { key in
                        Button(key.title) { input.press(key) }
                            .frame(maxWidth: .infinity, minHeight: 60)
                            .accessibilityLabel(key.accessibilityName)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 560)
        .disabled(!input.canSend)
    }
}

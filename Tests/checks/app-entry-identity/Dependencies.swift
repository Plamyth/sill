#if ENTRY_PROBE
import EntryProbeUI
final class SillAppDelegate {}
#else
import SwiftUI
import UIKit
final class SillAppDelegate: NSObject, UIApplicationDelegate {}
#endif

struct ContentView: View {
    init() {
        #if ENTRY_PROBE
        EntryProbe.content += 1
        #endif
    }
    #if !ENTRY_PROBE
    var body: some View { EmptyView() }
    #endif
}

struct CanvasWorkspace: View {
    init() {
        #if ENTRY_PROBE
        EntryProbe.workspace += 1
        #endif
    }
    #if !ENTRY_PROBE
    var body: some View { EmptyView() }
    #endif
}

extension View {
    func readsDuoPosture() -> some View { self }
}

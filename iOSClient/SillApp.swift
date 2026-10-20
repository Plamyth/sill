import SwiftUI

@main
struct SillApp: App {
    /// Only `buildMenu(with:)`: the Mac's menus in the iPad's menu bar on iPadOS 26 (SillAppDelegate).
    @UIApplicationDelegateAdaptor(SillAppDelegate.self) var appDelegate
    #if DEBUG
    @State private var runtimeReceiptError: String?
    #endif

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            switch CanvasRuntime.launch {
            case .isolated:
                CanvasWorkspace()
                    .onAppear {
                        do {
                            try CanvasRuntime.writeRuntimeReceipt()
                            runtimeReceiptError = nil
                        } catch {
                            runtimeReceiptError = "격리 테스트 실행 영수증을 저장하지 못했습니다. 테스트 설정을 확인하세요."
                        }
                    }
                    .overlay(alignment:.top) {
                        if let runtimeReceiptError {
                            Text(runtimeReceiptError)
                                .padding()
                                .accessibilityIdentifier("canvasTestRuntimeReceiptError")
                        }
                    }
            case .invalid:
                Text(CanvasRuntime.TestError.invalid.localizedDescription)
                    .padding()
                    .accessibilityIdentifier("canvasTestRuntimeError")
            case .normal:
                ContentView()
                    .readsDuoPosture()
            }
            #else
            // iOS 27.1 on the iPhone Duo: the hinge for the layouts (DuoPostureReader); nothing
            // before iOS 27.1 or on a device without a hinge.
            ContentView()
                .readsDuoPosture()
            #endif
        }
    }
}

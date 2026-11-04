import SwiftUI

@main
struct SillApp: App {
    /// Only `buildMenu(with:)`: the Mac's menus in the iPad's menu bar on iPadOS 26 (SillAppDelegate).
    @UIApplicationDelegateAdaptor(SillAppDelegate.self) var appDelegate
    #if DEBUG
    @State private var runtimeReceiptError: String?
    #endif

    private var isOfficialApp: Bool {
        ["com.ambrion.sillcanvas.ipad", "com.ambrion.sillcanvas.iphone"]
            .contains(Bundle.main.bundleIdentifier ?? "")
    }

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
                if isOfficialApp {
                    ContentView()
                        .readsDuoPosture()
                } else {
                    Text("이 앱에서는 Mac에 연결할 수 없습니다. 기존 정식 CCR Sill 앱을 열어 주세요.")
                        .padding()
                        .accessibilityIdentifier("sillAppIdentityError")
                }
            }
            #else
            // iOS 27.1 on the iPhone Duo: the hinge for the layouts (DuoPostureReader); nothing
            // before iOS 27.1 or on a device without a hinge.
            if isOfficialApp {
                ContentView()
                    .readsDuoPosture()
            } else {
                Text("이 앱에서는 Mac에 연결할 수 없습니다. 기존 정식 CCR Sill 앱을 열어 주세요.")
                    .padding()
                    .accessibilityIdentifier("sillAppIdentityError")
            }
            #endif
        }
    }
}

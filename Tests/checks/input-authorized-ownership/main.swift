import Foundation
import StreamProtocol

final class Device {}

@main @MainActor struct Checks {
    static var lastCaptured: [String] = []
    static func main() {
        var assertions = 0
        func check(_ condition: Bool) {
            if !condition {
                FileHandle.standardError.write(Data("FAIL assertion \(assertions + 1), logs=\(lastCaptured)\n".utf8))
            }
            precondition(condition); assertions += 1
        }
        func capture(_ action: () -> Void) -> [String] {
            let pipe = Pipe(); fflush(stdout)
            let saved = dup(STDOUT_FILENO)
            precondition(saved >= 0 && dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO) >= 0)
            action(); fflush(stdout)
            precondition(dup2(saved, STDOUT_FILENO) >= 0); close(saved)
            pipe.fileHandleForWriting.closeFile()
            let result = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .split(separator: "\n").map(String.init).filter { $0.hasPrefix("Test input:") && !$0.contains("up: the table") }
            lastCaptured = result
            return result
        }
        let a = Device(), b = Device(), aID = ObjectIdentifier(a), bID = ObjectIdentifier(b)
        let injector = InputInjector(); injector.dryRun = true; injector.testLog = true
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let keyDown = InputEvent.key(hidUsage: 4, down: true, modifiers: 0)
        check(capture { injector.apply(keyDown, in: rect, from: bID) }.count == 1)
        check(capture {
            injector.withAuthorization({ _ in false }) { injector.apply(keyDown, in: rect, from: aID) }
            injector.apply(.key(hidUsage: 4, down: false, modifiers: 0), in: rect, from: aID)
            injector.releaseInput(of: aID)
        }.isEmpty)
        check(!injector.isUpOfSomethingDown(.key(hidUsage: 4, down: false, modifiers: 0), from: aID))
        check(injector.isUpOfSomethingDown(.key(hidUsage: 4, down: false, modifiers: 0), from: bID))
        let bRelease = capture { injector.releaseInput(of: bID) }
        check(bRelease.count == 1 && bRelease[0].contains("key 0 up"))

        for (down, up) in [(PointerAction.leftDown, PointerAction.leftUp), (.rightDown, .rightUp)] {
            let event = InputEvent.pointer(down, x: 0.5, y: 0.5)
            check(capture {
                injector.withAuthorization({ _ in false }) { injector.apply(event, in: rect, from: aID) }
                injector.releaseInput(of: aID)
            }.isEmpty)
            check(capture { injector.apply(event, in: rect, from: bID) }.count == 1)
            check(capture { injector.releaseInput(of: aID) }.isEmpty)
            check(injector.isUpOfSomethingDown(.pointer(up, x: 0.5, y: 0.5), from: bID))
            check(capture { injector.releaseInput(of: bID) }.count == 1)
        }

        _ = capture {
            injector.apply(.key(hidUsage: 224, down: true, modifiers: 1), in: rect, from: aID)
            injector.apply(keyDown, in: rect, from: bID)
        }
        let partial = capture {
            injector.withAuthorization({ _ in false }) { injector.apply(keyDown, in: rect, from: aID) }
            injector.releaseInput(of: aID)
        }
        check(partial.count == 1 && partial[0].contains("key 59 flags changed (none)"))
        let stillB = capture { injector.releaseInput(of: bID) }
        check(stillB.count == 1 && stillB[0].contains("key 0 up"))
        for text in ["\n", "\t", "\u{8}", "가"] {
            check(capture {
                injector.withAuthorization({ _ in false }) { injector.apply(.text(text), in: rect, from: aID) }
            }.isEmpty)
        }
        check(capture {
            injector.withAuthorization({ _ in false }) { injector.chord(keyCode: 36, flags: 0) }
        }.isEmpty)
        var attempts = 0
        let partialText = capture {
            injector.withAuthorization({ operation in
                attempts += 1
                guard attempts == 1 else { return false }
                operation(); return true
            }) { injector.apply(.text("\n가"), in: rect, from: aID) }
        }
        check(partialText.count == 2 && partialText[0].contains("key 36 down") && partialText[1].contains("key 36 up"))
        attempts = 0
        let modifierPair = capture {
            injector.withAuthorization({ operation in
                attempts += 1
                guard attempts == 1 else { return false }
                operation(); return true
            }) { injector.chord(keyCode: 59, flags: 1 << 18) }
        }
        check(modifierPair.count == 2 && attempts == 1)
        print("PASS \(assertions) actual InputInjector ownership checks; dryRun=true and no CGEvent posted")
    }
}

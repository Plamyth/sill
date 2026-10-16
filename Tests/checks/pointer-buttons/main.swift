import Foundation
import StreamProtocol

final class Connection {}

@MainActor
struct Fixture {
    let a = Connection()
    let b = Connection()
    let injector: InputInjector
    let buffer: BufferedInput
    let rect = CGRect(x: 100, y: 200, width: 400, height: 200)
    var first: KeyStrokes.Device { ObjectIdentifier(a) }
    var second: KeyStrokes.Device { ObjectIdentifier(b) }

    init() {
        injector = InputInjector()
        injector.dryRun = true
        injector.testLog = true
        buffer = BufferedInput(injector)
    }

    func send(_ action: PointerAction, from device: KeyStrokes.Device? = nil,
              x: Double = 0.5, y: Double = 0.5, rect: CGRect? = nil) {
        precondition(injector.dryRun)
        injector.apply(.pointer(action, x: x, y: y), in: rect ?? self.rect, from: device ?? first)
    }

    func disconnect(_ device: KeyStrokes.Device? = nil) {
        precondition(injector.dryRun)
        #if SILL_BASELINE
        injector.releaseKeys(of: device ?? first)
        #else
        injector.releaseInput(of: device ?? first)
        #endif
    }

    func stillGoes(_ action: PointerAction, from device: KeyStrokes.Device) -> Bool {
        let event = InputEvent.pointer(action, x: 0.5, y: 0.5)
        #if SILL_BASELINE
        return injector.isUpOfSomethingDown(event)
        #else
        return injector.isUpOfSomethingDown(event, from: device)
        #endif
    }
}

@main
@MainActor
struct Check {
    static var checks = 0
    static var failures = 0

    static func check(_ ok: Bool, _ label: String) {
        checks += 1
        if !ok { failures += 1; print("FAIL: \(label)") }
    }

    static func capture(_ action: () -> Void) -> [String] {
        let pipe = Pipe()
        fflush(stdout)
        let saved = dup(STDOUT_FILENO)
        precondition(saved >= 0 && dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO) >= 0)
        action()
        fflush(stdout)
        precondition(dup2(saved, STDOUT_FILENO) >= 0)
        close(saved)
        pipe.fileHandleForWriting.closeFile()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.split(separator: "\n").map(String.init).filter {
            $0.hasPrefix("Test input: ") && !$0.contains("up: the table read again")
        }.map { String($0.dropFirst("Test input: ".count)) }
    }

    static func expect(_ label: String, _ expected: [String], _ action: () -> Void) {
        let actual = capture(action)
        check(actual == expected, "\(label). Expected \(expected), got \(actual)")
    }

    static func main() {
        for (down, up, button) in [(PointerAction.leftDown, PointerAction.leftUp, "left"),
                                   (.rightDown, .rightUp, "right")] {
            let f = Fixture()
            expect("\(button) drag disconnect", ["\(button) mouse down (none) at 300,300",
                   "\(button) mouse drag (none) at 400,360", "\(button) mouse up (none) at 400,360"]) {
                f.send(down)
                f.send(.move, x: 0.75, y: 0.8)
                f.disconnect()
            }
            expect("\(button) repeated disconnect and late up", []) {
                f.disconnect()
                f.disconnect()
                f.send(up)
            }
            expect("\(button) move after disconnect", ["pointer move (none)"]) { f.send(.move) }
            check(!f.stillGoes(up, from: f.first), "\(button) no held up after disconnect")

            let owned = Fixture()
            expect("\(button) foreign down and up cannot steal ownership", ["\(button) mouse down (none) at 300,300"]) {
                owned.send(down)
                owned.send(down)
                owned.send(down, from: owned.second, x: 0, y: 0)
                owned.send(up, from: owned.second, x: 0, y: 0)
                owned.disconnect(owned.second)
            }
            check(owned.stillGoes(up, from: owned.first), "\(button) owner up survives without a source")
            check(!owned.stillGoes(up, from: owned.second), "\(button) foreign up rejected without a source")
            expect("\(button) null source up keeps pointer location", ["\(button) mouse up (none) at 300,300"]) {
                owned.send(up, rect: .null)
                owned.disconnect()
            }
            expect("\(button) next client can acquire released button", ["\(button) mouse down (none) at 200,250",
                   "\(button) mouse up (none) at 200,250"]) {
                owned.send(down, from: owned.second, x: 0.25, y: 0.25)
                owned.disconnect()
                owned.send(up, from: owned.first)
                owned.disconnect(owned.second)
            }

            let buffered = Fixture()
            buffered.buffer.hold()
            expect("\(button) held down and repeated disconnect wait for activation", []) {
                buffered.buffer.send(.pointer(down, x: 0.5, y: 0.5), in: buffered.rect, from: buffered.first)
                buffered.buffer.disconnect(buffered.first)
                buffered.buffer.disconnect(buffered.first)
            }
            expect("\(button) held down flush releases afterward", ["\(button) mouse down (none) at 300,300",
                   "\(button) mouse up (none) at 300,300"]) { buffered.buffer.flush() }
            expect("\(button) held cleanup is idempotent", []) {
                buffered.buffer.flush()
                buffered.buffer.disconnect(buffered.first)
                buffered.send(up)
            }

            let handoff = Fixture()
            handoff.buffer.hold()
            expect("\(button) disconnect releases before next client's same button", [
                "\(button) mouse down (none) at 300,300",
                "\(button) mouse up (none) at 300,300",
                "\(button) mouse down (none) at 300,300",
                "\(button) mouse drag (none) at 400,350",
                "\(button) mouse up (none) at 400,350"
            ]) {
                handoff.buffer.send(.pointer(down, x: 0.5, y: 0.5), in: handoff.rect, from: handoff.first)
                handoff.buffer.disconnect(handoff.first)
                handoff.buffer.send(.pointer(down, x: 0.5, y: 0.5), in: handoff.rect, from: handoff.second)
                handoff.buffer.send(.pointer(.move, x: 0.75, y: 0.75), in: handoff.rect, from: handoff.second)
                handoff.buffer.flush()
                handoff.buffer.disconnect(handoff.second)
            }

            let dropped = Fixture()
            dropped.buffer.hold()
            expect("\(button) source switch discards held down", []) {
                dropped.buffer.send(.pointer(down, x: 0.5, y: 0.5), in: dropped.rect, from: dropped.first)
                dropped.buffer.disconnect(dropped.first)
                dropped.buffer.drop()
                dropped.buffer.flush()
            }

            #if !SILL_BASELINE
            let switching = Fixture()
            switching.buffer.hold()
            switching.buffer.send(.pointer(down, x: 0.5, y: 0.5), in: switching.rect, from: switching.first)
            switching.buffer.beginSwitch()
            expect("\(button) activation cannot replay old-source down during switch", []) {
                switching.buffer.flush()
                switching.buffer.drop()
                switching.buffer.endSwitch()
                switching.buffer.flush()
            }
            check(!switching.stillGoes(up, from: switching.first), "\(button) remains released after switch")
            #endif

            let alreadyDown = Fixture()
            _ = capture { alreadyDown.send(down) }
            alreadyDown.buffer.hold()
            expect("\(button) queued up survives source loss at current pointer", ["\(button) mouse up (none) at 300,300"]) {
                alreadyDown.buffer.send(.pointer(up, x: 0, y: 0), in: alreadyDown.rect, from: alreadyDown.first)
                alreadyDown.buffer.disconnect(alreadyDown.first)
                alreadyDown.buffer.drop()
                alreadyDown.send(up)
            }
        }

        let split = Fixture()
        expect("two clients own different buttons", ["left mouse down (none) at 300,300",
               "right mouse down (none) at 400,350", "left mouse up (none) at 400,350",
               "right mouse drag (none) at 300,300", "right mouse up (none) at 300,300",
               "pointer move (none)"]) {
            split.send(.leftDown)
            split.send(.rightDown, from: split.second, x: 0.75, y: 0.75)
            split.disconnect()
            split.send(.rightUp)
            split.send(.move, from: split.second)
            split.disconnect(split.second)
            split.send(.move)
        }

        let both = Fixture()
        expect("one client holds both buttons", ["left mouse down (none) at 300,300",
               "right mouse down (none) at 300,300", "left mouse up (none) at 300,300",
               "right mouse up (none) at 300,300"]) {
            both.send(.leftDown)
            both.send(.rightDown)
            both.disconnect()
            both.disconnect()
        }

        let interleaved = Fixture()
        interleaved.buffer.hold()
        expect("buffer keeps another client's button", ["left mouse down (none) at 300,300",
               "right mouse down (none) at 300,300", "left mouse up (none) at 300,300"]) {
            interleaved.buffer.send(.pointer(.leftDown, x: 0.5, y: 0.5), in: interleaved.rect, from: interleaved.first)
            interleaved.buffer.send(.pointer(.rightDown, x: 0.5, y: 0.5), in: interleaved.rect, from: interleaved.second)
            interleaved.buffer.disconnect(interleaved.first)
            interleaved.buffer.flush()
        }
        check(interleaved.stillGoes(.rightUp, from: interleaved.second), "buffer preserves second client's ownership")
        expect("buffer owner then disconnects", ["right mouse up (none) at 300,300"]) {
            interleaved.buffer.disconnect(interleaved.second)
        }

        let keyboard = Fixture()
        expect("disconnect preserves keyboard cleanup", ["key 49 down (none)", "key 53 down (none)",
               "left mouse down (none) at 300,300", "key 49 up (none)", "left mouse up (none) at 300,300",
               "key 53 up (none)"]) {
            keyboard.injector.apply(.key(hidUsage: 0x2C, down: true, modifiers: 0), in: keyboard.rect, from: keyboard.first)
            keyboard.injector.apply(.key(hidUsage: 0x29, down: true, modifiers: 0), in: keyboard.rect, from: keyboard.second)
            keyboard.send(.leftDown)
            keyboard.disconnect()
            keyboard.disconnect()
            keyboard.disconnect(keyboard.second)
        }

        let exit = Fixture()
        expect("host exit releases every owner once", ["left mouse down (none) at 300,300",
               "right mouse down (none) at 300,300", "left mouse up (none) at 300,300",
               "right mouse up (none) at 300,300"]) {
            exit.send(.leftDown)
            exit.send(.rightDown, from: exit.second)
            exit.injector.releaseAll()
            exit.injector.releaseAll()
        }

        print("\(checks - failures)/\(checks) pointer button checks passed; \(failures) failed. dryRun only.")
        Foundation.exit(failures == 0 ? 0 : 1)
    }
}

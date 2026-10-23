import Foundation
import Darwin

enum ProviderCallFailure: Error { case unavailable, expired }

@main struct WaitChecks {
    static func pair() -> [Int32] {
        var values: [Int32] = [-1, -1]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &values) == 0)
        return values
    }
    static func main() throws {
        var count = 0
        func expect(_ value: Bool) { precondition(value); count += 1 }
        func check(delay: Double) throws -> Double {
            let fds = pair(); defer { fds.forEach { Darwin.close($0) } }
            let writer = DispatchGroup(); writer.enter()
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                var byte: UInt8 = 42
                _ = send(fds[1], &byte, 1, 0); writer.leave()
            }
            let started = ProcessInfo.processInfo.systemUptime
            do { try ProductionWait.wait(fds[0], events: Int16(POLLIN), until: started + 4) }
            catch { writer.wait(); throw error }
            var byte: UInt8 = 0
            expect(recv(fds[0], &byte, 1, 0) == 1 && byte == 42)
            writer.wait()
            return ProcessInfo.processInfo.systemUptime - started
        }
        expect(try check(delay: 0.01) < 1)
        let late = try check(delay: 2.3)
        expect(late >= 2 && late < 4)
        print("lateReplySeconds=\(late)")
        let fds = pair(); defer { fds.forEach { Darwin.close($0) } }
        let start = ProcessInfo.processInfo.systemUptime
        do { try ProductionWait.wait(fds[0], events: Int16(POLLIN), until: start + 0.08); fatalError("missing expiry") }
        catch ProviderCallFailure.expired { expect(ProcessInfo.processInfo.systemUptime - start < 1) }
        let cancel = DispatchGroup(); cancel.enter()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { _ = shutdown(fds[0], SHUT_RDWR); cancel.leave() }
        do { try ProductionWait.wait(fds[0], events: Int16(POLLIN), until: ProcessInfo.processInfo.systemUptime + 4)
            var byte: UInt8 = 0
            expect(recv(fds[0], &byte, 1, 0) == 0) }
        catch ProviderCallFailure.unavailable { expect(true) }
        cancel.wait()
        for deadline in [ProcessInfo.processInfo.systemUptime - 1, Double.nan, Double.infinity] {
            do { try ProductionWait.wait(fds[0], events: Int16(POLLIN), until: deadline); fatalError("invalid deadline") }
            catch ProviderCallFailure.expired { expect(true) }
        }
        let invalid = pair(); Darwin.close(invalid[0]); defer { Darwin.close(invalid[1]) }
        do { try ProductionWait.wait(invalid[0], events: Int16(POLLIN), until: ProcessInfo.processInfo.systemUptime + 1)
            fatalError("invalid descriptor accepted") }
        catch ProviderCallFailure.unavailable { expect(true) }
        print("PASS \(count) actual socket wait assertions; no Host, HAL, or provider effect")
    }
}

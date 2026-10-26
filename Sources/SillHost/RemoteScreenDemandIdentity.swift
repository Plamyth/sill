import AppKit
import CoreGraphics
import Darwin
import StreamProtocol

enum RemoteScreenDemandIdentity {
    typealias Source = RemoteScreenDemandObservation.Source

    static func read(source: StreamSource, windowPID: pid_t? = nil, displayID: UInt32? = nil) -> Source? {
        switch source {
        case .window(let id):
            guard let windowPID, let owner = windowOwner(id), owner == windowPID,
                  let before = process(owner),
                  let app = NSRunningApplication(processIdentifier: owner), !app.isTerminated,
                  let bundle = app.bundleIdentifier, !bundle.isEmpty, bundle.utf8.count <= 255,
                  windowOwner(id) == owner, process(owner) == before else { return nil }
            return .window(.init(windowID: id, ownerPID: owner, ownerStartSeconds: before.seconds,
                ownerStartMicroseconds: before.microseconds, bundleIdentifier: bundle))
        case .desktop:
            guard let id = displayID, CGDisplayIsActive(id) != 0,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
                  let value = UUID(uuidString: CFUUIDCreateString(nil, uuid) as String) else { return nil }
            return .display(.init(displayID: id, displayUUID: value))
        case .none: return nil
        }
    }

    static func isCurrent(_ source: Source) -> Bool {
        switch source {
        case .window(let value):
            return read(source: .window(value.windowID), windowPID: value.ownerPID) == source
        case .display(let value):
            return read(source: .desktop, displayID: value.displayID) == source
        }
    }

    private struct Birth: Equatable {
        let seconds: UInt64
        let microseconds: UInt32
    }

    private static func process(_ pid: pid_t) -> Birth? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_pid == UInt32(pid), info.pbi_uid == getuid(), info.pbi_status != 5,
              info.pbi_start_tvsec > 0, info.pbi_start_tvusec < 1_000_000 else { return nil }
        return Birth(seconds: info.pbi_start_tvsec, microseconds: UInt32(info.pbi_start_tvusec))
    }

    private static func windowOwner(_ id: CGWindowID) -> pid_t? {
        guard let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
              let row = rows.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }),
              let owner = row[kCGWindowOwnerPID as String] as? NSNumber,
              owner.int64Value > 0, owner.int64Value <= Int64(Int32.max) else { return nil }
        return owner.int32Value
    }
}

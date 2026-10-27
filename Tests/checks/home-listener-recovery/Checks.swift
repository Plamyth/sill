var checks = 0
func check(_ value: @autoclosure () -> Bool, _ name: String) {
    checks += 1
    guard value() else { print("FAIL \(name)"); exit(1) }
    print("PASS \(name)")
}
func running() -> Harness {
    Clock.reset()
    let host = Harness()
    host.start(); Clock.advance()
    host.listener.report(.ready)
    return host
}

do {
    var policy = HomeListenerRecovery()
    check(policy.start() && !policy.start(), "start is admitted once")
    for delay in [2.0, 5, 15, 30, 30] {
        let wait = policy.failed()!
        check(wait.delay == delay, "bounded backoff \(delay)")
        check(policy.failed() == nil, "failure cannot reserve a second timer")
        check(policy.retry(wait.ticket) && !policy.retry(wait.ticket), "retry ticket is consumed once")
    }
    policy.ready()
    let wait = policy.failed()!
    check(wait.delay == 2, "ready resets failure budget")
    policy.stop()
    check(!policy.retry(wait.ticket) && !policy.start() && policy.failed() == nil,
          "stop is terminal for callbacks, retries and start")
}
do {
    let host = running()
    let old = host.listener
    let oldState = old.stateUpdateHandler!
    let oldService = old.serviceRegistrationUpdateHandler!
    let oldAccept = old.newConnectionHandler!
    var statuses = 0
    host.onListenerState = { _ in statuses += 1 }
    old.report(.failed(.posix(.ENETDOWN)))
    let work = host.homeRetryItem!
    oldState(.ready)
    oldState(.failed(.posix(.ENETDOWN)))
    check(host.readyPort == nil && statuses == 1, "failed listener cannot report ready or duplicate failure")
    Clock.advance(1.99)
    check(host.builds.isEmpty, "retry respects initial deadline")
    Clock.advance(1.02)
    check(host.builds.count == 1 && host.builds[0].1 == 4000, "failed home listener recreates on last bound port")
    let fresh = host.listener
    fresh.report(.ready)
    Clock.advance(1.5)
    check(fresh !== old && fresh.starts == 1 && host.readyPort == 4000 && fresh.service != nil,
          "replacement reaches ready and advertises once")
    let count = host.builds.count
    work.body()
    oldState(.failed(.posix(.ENETDOWN)))
    oldService(.remove(.service(name: "old", type: "unused", domain: "", interface: nil)))
    let connection = NWConnection(); oldAccept(connection)
    Clock.advance(100)
    check(host.builds.count == count && host.readyPort == 4000 && connection.cancelled && host.accepted == 0,
          "old timer and listener callbacks cannot mutate or admit")
    let current = NWConnection(); fresh.newConnectionHandler?(current)
    check(host.accepted == 1 && !current.cancelled, "current listener still admits through original accept boundary")
    fresh.report(.failed(.posix(.ENETDOWN)))
    check(host.homeRecovery.state != .stopped && host.homeRetryItem != nil, "new current failure reserves recovery")
}
do {
    let host = running()
    host.failBuilds = 2
    host.listener.report(.failed(.posix(.ENETDOWN)))
    Clock.advance(3.01)
    check(host.builds.count == 1 && host.homeRetryItem != nil, "failed recovery bind schedules next bounded retry")
    Clock.advance(6.01)
    check(host.builds.count == 2 && host.builds.allSatisfy { $0.1 == 4000 }, "recovery never falls back to a different port")
    let count = host.builds.count
    Clock.advance(21.99 - Clock.now)
    check(host.builds.count == count, "third failure waits for fifteen second backoff")
    Clock.advance(0.02)
    check(host.builds.count == 3, "repeated bind failure can recover later")
    host.listener.report(.ready); Clock.advance(1.5)
    check(host.readyPort == 4000, "same port becomes ready after obstruction clears")
}
do {
    let host = running()
    let monitor = host.homePathMonitor!
    monitor.report(.satisfied)
    host.listener.report(.failed(.posix(.ENETDOWN)))
    monitor.report(.satisfied)
    check(host.builds.isEmpty, "initial or repeated satisfied path does not bypass backoff")
    monitor.report(.unsatisfied); monitor.report(.satisfied)
    Clock.advance(1.01)
    check(host.builds.count == 1, "network return expedites one pending recovery")
    monitor.report(.unsatisfied); monitor.report(.satisfied)
    check(host.builds.count == 1, "network events cannot duplicate an in-flight swap")
    host.listener.report(.ready); Clock.advance(1.5)
    monitor.report(.unsatisfied); monitor.report(.satisfied); Clock.advance(40)
    check(host.builds.count == 1 && Clock.pending == 0, "healthy listener is not restarted and has no retry polling")
}
do {
    let host = running()
    host.listener.report(.failed(.posix(.ENETDOWN)))
    host.setPeerToPeer(true); Clock.advance(1.01)
    check(host.listener.parameters.includePeerToPeer && host.builds.count == 1,
          "configuration change supersedes pending failure retry")
    let first = host.listener
    host.setPeerToPeer(false); Clock.advance()
    first.report(.ready); Clock.advance(1.5)
    Clock.advance(1.01)
    check(host.listener !== first && !host.listener.parameters.includePeerToPeer,
          "in-flight configuration changes coalesce to latest desired settings")
    host.listener.report(.ready); Clock.advance(40)
    check(host.builds.count == 2, "cancelled recovery timer cannot cause duplicate configuration swap")
}
do {
    let host = running()
    host.listener.report(.failed(.posix(.ENETDOWN)))
    let work = host.homeRetryItem!
    let monitor = host.homePathMonitor!
    let callback = host.listener.stateUpdateHandler!
    host.stopHomeListener(); Clock.advance()
    work.body(); callback(.ready)
    monitor.report(.unsatisfied); monitor.report(.satisfied)
    host.start(); host.setPeerToPeer(true); Clock.advance(100)
    check(host.builds.isEmpty && host.readyPort == nil && host.homePathMonitor == nil && monitor.cancelled,
          "manual stop defeats late timer, ready, network and explicit start")
    check(Clock.pending == 0 && host.homeRecovery.state == .stopped, "stopped host leaves no work chain")
}
for acknowledge in [true, false] {
    let host = running()
    host.listener.cancellationAcknowledged = acknowledge
    host.listener.report(.failed(.posix(.ENETDOWN)))
    Clock.advance(2)
    host.stopHomeListener(); Clock.advance(100)
    check(host.builds.count <= 1 && host.listener.service == nil && host.readyPort == nil,
          "stop invalidates cancellation and advertisement timers, ACK=\(acknowledge)")
}
do {
    let host = running()
    let old = host.listener
    old.cancellationAcknowledged = false
    let callback = old.stateUpdateHandler!
    let accept = old.newConnectionHandler!
    old.report(.failed(.posix(.ENETDOWN)))
    Clock.advance(2)
    callback(.ready)
    let connection = NWConnection(); accept(connection)
    check(host.readyPort == nil && host.builds.isEmpty && connection.cancelled,
          "old generation is rejected during cancellation before listener identity changes")
    Clock.advance(1.01)
    check(host.builds.count == 1 && host.builds[0].1 == 4000,
          "cancel timeout preserves recovery port without acknowledgement")
}
do {
    Clock.reset()
    let host = Harness(); host.homeMode = .closed("no identity")
    host.start(); Clock.advance(100)
    check(host.homePathMonitor == nil && !host.started && host.listener.starts == 0 && host.builds.isEmpty,
          "closed trust boundary never starts listener or network watcher")
}
print("PASS \(checks) home listener recovery checks; real listeners=0, devices=0, audio=0, HTTP=0")

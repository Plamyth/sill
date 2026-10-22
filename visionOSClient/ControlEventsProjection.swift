import Foundation

extension ControlEventsCodec {
    static func project(_ document: ControlEventsDocument) throws -> ControlEventsProjection {
        let root = document.root
        var sources = [ControlEventsSourceObservation]()
        if let raw = root["sourceConnections"], raw != .null {
            guard let rows = root.rows("sourceConnections") else { throw Failure.invalidProjection }
            for row in rows {
                guard let name = row.text("provider"), let provider = ControlEventsProvider(rawValue: name),
                      ["connected", "stale", "unavailable", "unsupported"].contains(row.text("state") ?? "unavailable") else { throw Failure.invalidProjection }
                sources.append(ControlEventsSourceObservation(provider: provider,
                    support: row.text("state") == "unsupported" ? .unsupported("본체가 이 소스의 원본 이벤트를 제공하지 않습니다.") : .unknown,
                    connection: ControlEventsConnectionObservation(state: try optionalText(row, "state"),
                        observedAt: try optionalText(row, "observedAt"), connectedAt: try optionalText(row, "connectedAt")),
                    connected: try optionalFlag(row, "connected"), owner: try optionalText(row, "owner"),
                    sessionID: try optionalText(row, "sessionId"), runID: try optionalText(row, "runId"),
                    sourceRevision: row["sourceRevision"], readOnly: try optionalFlag(row, "readOnly"), capabilities: row["capabilities"]))
            }
        }
        var work = [ControlEventsWork]()
        var unsupportedRows = 0
        var codexIDs = Set<String>()
        for name in ["threads", "catalog"] {
            for row in root.rows(name) ?? [] {
                guard row.text("source") == "codex" else { unsupportedRows += 1; continue }
                guard let id = row.text("id"), ControlEventsReducer.validID(id) else { throw Failure.invalidProjection }
                guard codexIDs.insert(id).inserted else { continue }
                let owner = try optionalText(row, "owner")
                work.append(ControlEventsWork(id: ControlEventsWorkID(provider: .codex, originalID: id,
                    sessionID: id, runID: try optionalText(row, "activeTurnId")), title: row.text("title") ?? id,
                    ownerID: owner == "미확인" ? nil : owner,
                    execution: ControlEventsExecutionObservation(state: try optionalText(row, "status"), observedAt: try optionalText(row, "observedAt")),
                    connection: ControlEventsConnectionObservation(state: nil, observedAt: nil, connectedAt: nil)))
            }
        }
        var adapterError: String?
        var truncated = false
        if let value = root["unifiedControl"], value != .null {
            guard case .object(let unified) = value, unified["schema"] == .number(1),
                  let rows = unified.rows("rows") else { throw Failure.invalidProjection }
            work.removeAll()
            adapterError = try optionalText(unified, "error")
            truncated = try optionalFlag(unified, "truncated") ?? false
            for row in rows {
                guard let source = row.text("source"), let provider = ControlEventsProvider(rawValue: source),
                      row.text("provider") == source, let key = row.text("key"),
                      let originalID = row.text("externalId"), !originalID.isEmpty else {
                    unsupportedRows += 1
                    continue
                }
                let ownerVerified = try optionalFlag(row, "ownerVerified")
                let explicitExecution = try optionalText(row, "executionStatus")
                let statusSource = try optionalText(row, "statusSource")
                let execution = provider == .codex ? try optionalText(row, "status") :
                    (statusSource?.isEmpty == false ? explicitExecution : nil)
                var item = ControlEventsWork(id: ControlEventsWorkID(provider: provider, originalID: originalID,
                    sessionID: try optionalText(row, "sessionId"), runID: try optionalText(row, "runId"), hostID: try optionalText(row, "hostId"), rowKey: key,
                    instanceID: try optionalText(row, "instanceId"), startedAt: try optionalText(row, "startedAt"),
                    workspaceIdentity: try optionalText(row, "workspaceIdentity")), title: row.text("title") ?? originalID,
                    ownerID: ownerVerified == true ? try optionalText(row, "ownerThreadId") : nil,
                    execution: ControlEventsExecutionObservation(
                        state: execution,
                        observedAt: execution == nil ? nil : try optionalText(row, "observedAt")),
                    connection: ControlEventsConnectionObservation(state: try optionalText(row, "connectionState"),
                        observedAt: nil, connectedAt: try optionalText(row, "connectedAt")))
                item.ownerVerified = ownerVerified
                item.sourceRevision = row["sourceRevision"]
                item.agentStatus = try optionalText(row, "agentStatus")
                item.statusSource = statusSource
                item.fresh = try optionalFlag(row, "fresh")
                item.readOnly = try optionalFlag(row, "readOnly")
                item.capabilities = row["capabilities"]
                item.threadID = try optionalText(row, "threadId")
                item.recordObservedAt = try optionalText(row, "observedAt")
                item.reportedStatus = try optionalText(row, "status")
                item.activeTurnID = try optionalText(row, "activeTurnId")
                work.append(item)
            }
        }
        return ControlEventsProjection(sources: sources, work: work, unsupportedRows: unsupportedRows,
                                       adapterError: adapterError, truncated: truncated)
    }

    private static func optionalText(_ row: [String: ControlEventsValue], _ key: String) throws -> String? {
        guard let value = row[key], value != .null else { return nil }
        guard case .string(let text) = value else { throw Failure.invalidProjection }
        if ["observedAt", "connectedAt", "startedAt"].contains(key), ControlEventsReducer.date(text) == nil { throw Failure.invalidProjection }
        return text
    }

    private static func optionalFlag(_ row: [String: ControlEventsValue], _ key: String) throws -> Bool? {
        guard let value = row[key], value != .null else { return nil }
        guard case .bool(let flag) = value else { throw Failure.invalidProjection }
        return flag
    }
}

import Foundation

/// What the host streams. The client decides; the host only ever streams one source.
public enum StreamSource: Codable, Hashable {
    case none
    case window(UInt32)   // CGWindowID, stable for the life of the window
    case desktop          // one Mac display; its selection is carried separately
}

/// Kind 6 retains the StreamSource enum at the JSON root for older hosts.
public struct SourceRequest: Codable, Equatable {
    public enum Origin: String, Codable { case human, automatic }
    public let source: StreamSource
    public let origin: Origin?
    public let selectionRevision: String?

    public init(source: StreamSource, origin: Origin? = nil, selectionRevision: String? = nil) {
        self.source = source; self.origin = origin; self.selectionRevision = selectionRevision
    }

    private enum CodingKeys: String, CodingKey { case selectionOrigin, selectionRevision }
    public init(from decoder: Decoder) throws {
        let metadata = try decoder.container(keyedBy: CodingKeys.self)
        if metadata.contains(.selectionOrigin) || metadata.contains(.selectionRevision) {
            origin = try metadata.decode(Origin.self, forKey: .selectionOrigin)
            if metadata.contains(.selectionRevision) {
                let revision = try metadata.decode(String.self, forKey: .selectionRevision)
                guard !revision.isEmpty, revision.utf8.count <= 128 else {
                    throw DecodingError.dataCorruptedError(forKey: .selectionRevision, in: metadata, debugDescription: "Invalid selection revision")
                }
                selectionRevision = revision
            } else { selectionRevision = nil }
            if origin == .automatic, selectionRevision == nil {
                throw DecodingError.keyNotFound(CodingKeys.selectionRevision, .init(codingPath: decoder.codingPath, debugDescription: "Automatic request needs original revision"))
            }
        } else { origin = nil; selectionRevision = nil }
        // Synthesized enum decoding requires exactly one source key.
        source = try StreamSource(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try source.encode(to: encoder)
        var metadata = encoder.container(keyedBy: CodingKeys.self)
        try metadata.encodeIfPresent(origin, forKey: .selectionOrigin)
        try metadata.encodeIfPresent(selectionRevision, forKey: .selectionRevision)
    }
}

public struct DisplayInfo: Codable, Equatable, Identifiable {
    public var id: UInt32
    public var name: String
    public var width: Int
    public var height: Int
    public var isMain: Bool

    public init(id: UInt32, name: String, width: Int, height: Int, isMain: Bool) {
        self.id = id; self.name = name; self.width = width; self.height = height; self.isMain = isMain
    }
}

/// Human display choice, valid only for this host's current inventory.
/// Automatic display restore is unsupported. Kind 211 has no typed origin/revision admission.
/// Display IDs are never saved across reconnects.
public struct DisplaySelection: Codable, Equatable {
    public var displayID: UInt32
    public var inventoryID: UUID

    public init(displayID: UInt32, inventoryID: UUID) {
        self.displayID = displayID; self.inventoryID = inventoryID
    }
}

/// One on-screen Mac window, as the client sees it. WindowList order is stable: first seen first.
public struct WindowInfo: Codable, Hashable, Identifiable {
    public var id: UInt32
    public var title: String
    public var appName: String
    public var bundleID: String
    public var width: Int      // points
    public var height: Int

    public init(id: UInt32, title: String, appName: String, bundleID: String, width: Int, height: Int) {
        self.id = id; self.title = title; self.appName = appName; self.bundleID = bundleID
        self.width = width; self.height = height
    }
}

/// An installed app, for the drawer's "All apps" section.
public struct AppInfo: Codable, Hashable, Identifiable {
    public var id: String { bundleID }
    public var name: String
    public var bundleID: String

    public init(name: String, bundleID: String) { self.name = name; self.bundleID = bundleID }
}

public struct FetchCatalog: Codable, Equatable {
    public let requestID: UUID
    public init(requestID: UUID) { self.requestID = requestID }
}

public struct WindowList: Codable {
    public var macName: String
    public var windows: [WindowInfo]
    public var active: StreamSource
    /// Random, picked once per launch of the host and the same in every list to every device: two
    /// connections whose lists carry the same one reach the same running host. A name cannot tell
    /// that (two Macs can share one, and mDNS renames neither when they share no link), and a
    /// device moving its session from AWDL to the network must not land on another Mac. Optional:
    /// nil from a host older than 2026-09-24, and an older device ignores the key.
    public var launchID: String?
    /// The host's version: Sill.app's CFBundleShortVersionString ("0.4.0"); nil from SillHost (no
    /// bundle) and from hosts before 2026-09-25. For later devices: which Mac to update, and to what
    /// (docs/update-notice-plan.md §14).
    public var hostVersion: String?
    /// The host's SillProtocol.current; nil from hosts before 2026-09-25, which speak 1. The JSON key
    /// is "protocol".
    public var `protocol`: Int?
    /// Which trackpad gestures this host takes (kind 28, Gesture.swift): 1 is the six of
    /// `TrackpadGesture.names`, each turned into the Mac's own shortcut. Nil from every host before
    /// 2026-09-27, to which a device sends no kind 28. A later generation of gestures says 2 and
    /// goes only to a host that says so.
    public var gestures: Int?
    /// This fork's optional remote sound path. A device sends kind 200 only when this is 1.
    /// Nil from older hosts; older devices ignore this field.
    public var remoteAudio: Int?
    public var audioPrivacy: AudioPrivacyState?
    public var catalogRefresh: Int?
    public var responseRequestID: UUID?

    /// The dedicated source-intent CAS, independent of video and input generations.
    public var selectionRevision: String?
    /// Changes whenever the active source changes, including A → B → A. Echoed in SourceInput;
    /// scoped connections must echo it. Legacy connections pin source selection and keep their
    /// original input format until they disconnect or negotiate scoped input.
    public var inputGeneration: String?
    public var presentationInput: Int?
    public var videoEpoch: VideoEpoch?
    public var microphone: MicrophoneCapability?
    /// Version 1 permits kind 211. Absent on hosts without monitor selection.
    public var displaySelection: Int?
    public var displays: [DisplayInfo]?
    public var displayInventoryID: UUID?
    public var activeDisplayID: UInt32?
    public var desktopSelectionRequired: Bool?
    /// Apps pinned to the Mac Dock, in Dock order. Absent on older hosts.
    public var dockApps: [AppInfo]?

    public init(macName: String, windows: [WindowInfo], active: StreamSource, launchID: String? = nil,
                hostVersion: String? = nil, protocol: Int? = nil, gestures: Int? = nil,
                remoteAudio: Int? = nil, selectionRevision: String? = nil, inputGeneration: String? = nil, presentationInput: Int? = nil, videoEpoch: VideoEpoch? = nil, microphone: MicrophoneCapability? = nil,
                displaySelection: Int? = nil, displays: [DisplayInfo]? = nil, displayInventoryID: UUID? = nil,
                activeDisplayID: UInt32? = nil, desktopSelectionRequired: Bool? = nil,
                dockApps: [AppInfo]? = nil, audioPrivacy: AudioPrivacyState? = nil,
                catalogRefresh: Int? = nil, responseRequestID: UUID? = nil) {
        self.macName = macName; self.windows = windows; self.active = active; self.launchID = launchID
        self.hostVersion = hostVersion; self.protocol = `protocol`; self.gestures = gestures
        self.remoteAudio = remoteAudio
        self.selectionRevision = selectionRevision
        self.audioPrivacy = audioPrivacy
        self.catalogRefresh = catalogRefresh
        self.responseRequestID = responseRequestID
        self.inputGeneration = inputGeneration
        self.presentationInput = presentationInput
        self.videoEpoch = videoEpoch
        self.microphone = microphone
        self.displaySelection = displaySelection
        self.displays = displays
        self.displayInventoryID = displayInventoryID
        self.activeDisplayID = activeDisplayID
        self.desktopSelectionRequired = desktopSelectionRequired
        self.dockApps = dockApps
    }
}

public struct LaunchApp: Codable {
    public var bundleID: String
    public init(bundleID: String) { self.bundleID = bundleID }
}

/// Client → host: what the bar's long-press menu asks of a window, the three traffic lights.
public struct WindowCommand: Codable {
    public enum Action: String, Codable { case close, minimize, fullScreen }
    public var id: UInt32
    public var action: Action
    public init(id: UInt32, action: Action) { self.id = id; self.action = action }
}

/// JSON payloads. Everything here is small and infrequent; frames never go through JSON.
public enum Wire {
    public static func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }
}

/// Binary image payloads: a key, then the image bytes.
public enum ImageBlob {
    /// windowID(4, BE) + JPEG
    public static func encodeThumbnail(windowID: UInt32, jpeg: Data) -> Data {
        var d = Data(capacity: 4 + jpeg.count)
        d.appendBigEndian(windowID)
        d.append(jpeg)
        return d
    }
    public static func decodeThumbnail(_ d: Data) -> (windowID: UInt32, jpeg: Data)? {
        guard d.count > 4 else { return nil }
        return (d.readBigEndian(UInt32.self, at: 0), d.subdata(in: (d.startIndex + 4)..<d.endIndex))
    }

    /// bundleIDLength(2, BE) + bundleID UTF-8 + PNG
    public static func encodeIcon(bundleID: String, png: Data) -> Data {
        let id = Data(bundleID.utf8)
        var d = Data(capacity: 2 + id.count + png.count)
        d.appendBigEndian(UInt16(id.count))
        d.append(id)
        d.append(png)
        return d
    }
    public static func decodeIcon(_ d: Data) -> (bundleID: String, png: Data)? {
        guard d.count > 2 else { return nil }
        let len = Int(d.readBigEndian(UInt16.self, at: 0))
        guard d.count > 2 + len else { return nil }
        let idStart = d.startIndex + 2
        guard let id = String(data: d.subdata(in: idStart..<(idStart + len)), encoding: .utf8) else { return nil }
        return (id, d.subdata(in: (idStart + len)..<d.endIndex))
    }
}

public struct VideoEpoch: Codable, Equatable {
    public struct Geometry: Codable, Equatable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x; self.y = y; self.width = width; self.height = height
        }

        public var isValid: Bool {
            x.isFinite && y.isFinite && width.isFinite && height.isFinite && width > 0 && height > 0
        }
    }

    public let id: UUID
    public let generation: String
    public let source: StreamSource
    public let geometry: Geometry
    public let windowGeometry: Geometry?
    public let width: Int
    public let height: Int

    public init(id: UUID = UUID(), generation: String, source: StreamSource, geometry: Geometry, width: Int, height: Int, windowGeometry: Geometry? = nil) {
        self.id = id; self.generation = generation; self.source = source; self.geometry = geometry
        self.width = width; self.height = height
        self.windowGeometry = windowGeometry
    }

    public var isValid: Bool {
        !generation.isEmpty && source != .none && geometry.isValid && (windowGeometry?.isValid ?? true) && (1...32768).contains(width) && (1...32768).contains(height)
    }

    public func matchesEncodedDimensions(width: Int, height: Int) -> Bool {
        isValid && self.width == width && self.height == height
    }

    public func matches(source: StreamSource, generation: String?) -> Bool {
        isValid && self.source == source && self.generation == generation
    }
}


public enum VideoEpochAdmission: Equatable {
    case stopped
    case preparing(VideoEpoch)
    case committed(VideoEpoch)

    public var current: VideoEpoch? {
        if case .committed(let epoch) = self { return epoch }
        return nil
    }

    public func admits(_ id: UUID?) -> Bool { id != nil && current?.id == id }
}

public struct MicrophoneCapability: Codable, Equatable {
    public let peer: UUID
    public let destination: UUID
    public let generation: UUID

    public init(peer: UUID, destination: UUID, generation: UUID) {
        self.peer = peer; self.destination = destination; self.generation = generation
    }
}

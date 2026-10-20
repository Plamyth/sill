import Foundation

enum LocalAudioRelayClosure {
    private static let serverHashes: [String: String] = [
        "server/audio-forwarding-authority.js": "99b63f148fda56d2333c1d2359eb071780ae48be53973ea716e02e2cf0254965",
        "server/audio-forwarding-journal.js": "4a9f59926f385019f0e83716ca9840c6cc5c3cbc5e1259322c9e9fb82fce27dc",
        "server/audio-forwarding-proxy.js": "16095aadc890044cf626f6679fd8f5cbf3ebb7db7f4126ffa0c695f543828351",
        "server/audio-router.py": "a755159ae8c56c1bb902716ad4ffac6c7819782c62f017b14edc22bed88b59e0",
        "server/audio-session.js": "cd741c69faf3514da0fe90582c4aca1df490c087ead72510f090346a90ace938",
        "server/control-room-server.js": "98197786d83bb5fa67ad5997393aa19642e8faf1506264d6b59b28d68ea0faef",
        "server/desktop-state-client.js": "27bf858391739f9fe49a3157c47f26f7f2199a124d90720705271b62cf4e6ea1",
        "server/desktop-state-socket.js": "4cbaaa2eff7ba8527bb8fa538f8c65318a10366558a017bc7d8a4841635603fe",
        "server/mobile-automation.js": "082a5d2dfe4a9afbb635ad261b6130ee8db3e1da772fd3f997f933077c34815f",
        "server/mobile-executions.js": "927dcebeecfccb3ab64711c46ff02861bc325790dd1360a17e6553117b2702bb",
        "server/mobile-pc-status.js": "fd1be7219f22ad8eecf1a8511330fa44332911f0efd689d37c924883c61068ec",
        "server/mobile-surface.js": "04a40e4a1e56607a96e572951ddabec994bb3ae57233e0b4b362b8c35a4dc41c",
        "server/mobile-update.js": "13015861fb2cc260aae202e0b83e4dfa7c58dd537b034e7f20151366c12cac46",
        "server/native-audio-control.js": "f9fecf43b129e5f19e8e6babe9aa25def1579e0a0259c1d329ef3e71ebfe2a0d",
        "server/shared-cards-model.js": "4fa19ac7edc61f14e9128e28cf4d723556d683bcc54625c2472527f769b85d8c",
        "server/shared-cards-surface.js": "64f7a7f9057e451a592f6e1d1aa69aaf5d2dba824d1de3b6702f3c3c12084575",
    ]

    static func validate(_ inventory: LocalAudioRelayInventory) throws {
        guard inventory.manifest.runtimeABI == "native-audio-forwarding-stdio-v3",
              inventory.manifest.nodeSourceCommit == LocalAudioRelayManifest.nodeCommit else {
            throw LocalAudioRelayLaunchFailure.unsupportedRuntimeABI
        }
        let files = Dictionary(uniqueKeysWithValues: inventory.manifest.entries.filter { $0.kind == .file }.map { ($0.path, $0) })
        guard Set(files.keys.filter { $0.hasPrefix("server/") }) == Set(serverHashes.keys),
              serverHashes.allSatisfy({ files[$0.key]?.sha256 == $0.value }),
              files["python/lib/python3.13/site-packages/sounddevice.py"]?.sha256 ==
                "6336351c4771da61a3039f0aeb603da4d975d7b4525d56224016389433ccde34",
              !files.keys.contains(where: { $0.hasSuffix(".pth") || $0.hasSuffix("/sitecustomize.py") || $0.hasSuffix("/usercustomize.py") }) else {
            throw LocalAudioRelayLaunchFailure.runtimePackagingUnverified
        }
        let root = inventory.package.appendingPathComponent("runtime", isDirectory: true)
        let declared = Dictionary(uniqueKeysWithValues: inventory.manifest.dependencies.map { ($0.source, $0) })
        var native = Set<String>()
        for (path, _) in files {
            let url = root.appendingPathComponent(path)
            guard let dependency = declared[path] else { throw LocalAudioRelayLaunchFailure.runtimePackagingUnverified }
            let actual = try LocalAudioRelayMachO.inspect(Data(contentsOf: url, options: .mappedIfSafe))
            var bundled = Set<String>(), system = Set<String>()
            if let actual {
                native.insert(path)
                for search in actual.rpaths {
                    _ = try resolve(search, from: url, root: root, files: files, directory: true)
                }
                for load in actual.loads {
                    if load.hasPrefix("/usr/lib/") || load.hasPrefix("/System/Library/") {
                        guard LocalAudioRelayInventory.validRelative(String(load.dropFirst())) else {
                            throw LocalAudioRelayLaunchFailure.runtimePackagingUnverified
                        }
                        system.insert(load)
                    } else {
                        bundled.insert(try resolve(load, from: url, root: root, files: files, directory: false))
                    }
                }
            }
            guard bundled == Set(dependency.bundled), system == Set(dependency.system) else {
                throw LocalAudioRelayLaunchFailure.runtimePackagingUnverified
            }
        }
        guard native.isSuperset(of: ["node/bin/node", "python/bin/python3.13", "python/Python",
                "python/lib/python3.13/site-packages/_cffi_backend.cpython-313-darwin.so",
                "python/lib/python3.13/site-packages/_sounddevice_data/portaudio-binaries/libportaudio.dylib"]) else {
            throw LocalAudioRelayLaunchFailure.runtimePackagingUnverified
        }
        try inventory.recheck()
    }

    private static func resolve(_ path: String, from image: URL, root: URL,
                                files: [String: LocalAudioRelayManifest.Entry], directory: Bool) throws -> String {
        guard path.hasPrefix("@loader_path/"), !path.contains("\0"), !path.contains("\\") else {
            throw LocalAudioRelayLaunchFailure.runtimePackagingUnverified
        }
        let target = image.deletingLastPathComponent().appendingPathComponent(String(path.dropFirst("@loader_path/".count)))
            .standardizedFileURL
        guard target.path.hasPrefix(root.path + "/"), target.resolvingSymlinksInPath().path == target.path else {
            throw LocalAudioRelayLaunchFailure.runtimePackagingUnverified
        }
        let relative = String(target.path.dropFirst(root.path.count + 1))
        if directory {
            guard (try? target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                throw LocalAudioRelayLaunchFailure.runtimePackagingUnverified
            }
        } else if files[relative] == nil { throw LocalAudioRelayLaunchFailure.runtimePackagingUnverified }
        return relative
    }
}

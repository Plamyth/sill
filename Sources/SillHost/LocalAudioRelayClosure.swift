import Foundation

enum LocalAudioRelayClosure {
    private static let serverHashes: [String: String] = [
        "server/audio-forwarding-authority.js": "ad9bc1a57242af3b981b9c1f46fd5adb76b9bafdd3c7a9e790158fd5b853188b",
        "server/audio-forwarding-journal.js": "4a9f59926f385019f0e83716ca9840c6cc5c3cbc5e1259322c9e9fb82fce27dc",
        "server/audio-forwarding-proxy.js": "b7cdb3504785a315a2c1ed304e0d62583c60506f70c8fad0f56231c1337ff48c",
        "server/audio-router.py": "a755159ae8c56c1bb902716ad4ffac6c7819782c62f017b14edc22bed88b59e0",
        "server/audio-session.js": "6d8e589c80e3c7faef785f50bc9d04fe95440539b9bdadaa946b6204e55f4e7e",
        "server/common-release.js": "3e623cb451ed1cbe1b3139ff3bc752c4fcba2f26cdba96fc495888579393f7a0",
        "server/control-events-relay.js": "aff9047a4f58cddf10b265bdda9556de659867c9846dd08479778158cb59e51b",
        "server/control-privacy-policy.js": "6c7ab01210c7e1dbaddf0b85e9b23555626019b750e03b0436cb4ebef4f22700",
        "server/control-room-server.js": "afbaa3908d8167b9443bbc07bf35fe60a687218bbcdcf4e4c64fec66e841f49e",
        "server/desktop-state-client.js": "27bf858391739f9fe49a3157c47f26f7f2199a124d90720705271b62cf4e6ea1",
        "server/desktop-state-socket.js": "4cbaaa2eff7ba8527bb8fa538f8c65318a10366558a017bc7d8a4841635603fe",
        "server/device-enrollment-provider.js": "40cd47d1cb1447d06268612fcdb115b824d8f1dcc2d49bfd4848ea4d3cc20571",
        "server/device-enrollment.js": "38f378e0955b3cf330fd90452cf7f7b22f5937f4fa177eb1af102d685d721128",
        "server/enrollment-core-client.js": "8713e0fccbf0ea461c31b8aa50b7499c1a2ba1a9694603f97e5611639003f6b7",
        "server/enrollment-json.js": "fd1a9e2393decef0238426ec07c84f6fcdcf0dbaf6c91c632fadbca6c04b0489",
        "server/mobile-automation.js": "519e41b9ed6a2a614a92d1b815cf59e9bae4741917a3568feb7c1af011f37579",
        "server/mobile-control.js": "376a68815e29f8b936ae0b09f5f4c7833ad7f84c78760533bf0c66a2e38b13bc",
        "server/mobile-executions.js": "927dcebeecfccb3ab64711c46ff02861bc325790dd1360a17e6553117b2702bb",
        "server/mobile-pc-status.js": "fd1be7219f22ad8eecf1a8511330fa44332911f0efd689d37c924883c61068ec",
        "server/mobile-surface.js": "dda60d218dfdac028fbc94acffd9d4082abfe5b346ac4f7fea753010caf6ed68",
        "server/mobile-update.js": "604a8caa47ad2b9a74a64b67fda5a49be2054b61c17369161129b6cc09ffc1a4",
        "server/native-audio-control.js": "87fa4e798d51102e8dca620444fd579571082aa6ba7a2d07b3e1b8c8916b710f",
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
              !files.keys.contains(where: { path in
                  let path = path.lowercased()
                  return [".pth", ".pyc", ".pyo", ".zip", ".egg", ".whl", ".pyz"].contains(where: path.hasSuffix) ||
                      path.split(separator: "/").contains("__pycache__") ||
                      path.hasSuffix("/sitecustomize.py") || path.hasSuffix("/usercustomize.py")
              }) else {
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

import Foundation
import Network
import Darwin
import dnssd

struct OwnerWiredTarget {
    let binding: OwnerWiredPolicy.Binding
    let key: String
    let interface: NWInterface
    let address: [UInt8]
    let host: String
    var candidate: RemoteDialPolicy.Candidate {
        .init(host: host, port: binding.port, kind: "lan", via: "USB")
    }
    var endpoint: NWEndpoint {
        .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(binding.port))!)
    }
    func current() -> Bool {
        guard if_nametoindex(interface.name) == UInt32(interface.index) else { return false }
        return OwnerWiredPolicy.addressAllowed(address, replyIndex: UInt32(interface.index), scopeIndex: UInt32(interface.index),
                                              interfaceIndex: UInt32(interface.index), interface: StreamClient.policyInterface(interface),
                                              own: StreamClient.ownAddresses())
    }
    func matches(_ path: NWPath?) -> Bool {
        guard current(), let path, path.status == .satisfied else { return false }
        return path.usesInterfaceType(.wiredEthernet) && path.availableInterfaces.contains {
            $0.index == interface.index && $0.name == interface.name && $0.type == .wiredEthernet
        }
    }
}

/// DNS-SD refs, callbacks, timeout and cancellation are all confined to the main queue.
/// No TXT, advertised port, recognition key, or owner receipt is a source of trust here.
final class OwnerWiredResolver {
    private var resolveRef: DNSServiceRef?
    private var addressRef: DNSServiceRef?
    private var timeout: DispatchWorkItem?
    private var completion: ((OwnerWiredTarget?) -> Void)?
    private let binding: OwnerWiredPolicy.Binding
    private let key: String
    private let interface: NWInterface

    init(binding: OwnerWiredPolicy.Binding, key: String, interface: NWInterface) {
        self.binding = binding; self.key = key; self.interface = interface
    }

    func start(service: NWEndpoint, completion: @escaping (OwnerWiredTarget?) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.completion = completion
        guard interface.type == .wiredEthernet,
              if_nametoindex(interface.name) == UInt32(interface.index),
              DiscoveryPolicy.carriesOnlyLinkLocal(interface.name, own: StreamClient.ownAddresses()),
              case .service(let name, let type, let domain, _) = service else { finish(nil); return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let error = DNSServiceResolve(&resolveRef, 0, UInt32(interface.index), name, type, domain, { _, _, index, error, _, host, _, _, _, context in
            guard let context else { return }
            let resolver = Unmanaged<OwnerWiredResolver>.fromOpaque(context).takeUnretainedValue()
            guard resolver.completion != nil else { return }
            guard error == kDNSServiceErr_NoError, index == UInt32(resolver.interface.index), let host else {
                resolver.finish(nil); return
            }
            resolver.resolveAddresses(String(cString: host))
        }, context)
        guard error == kDNSServiceErr_NoError, let resolveRef,
              DNSServiceSetDispatchQueue(resolveRef, .main) == kDNSServiceErr_NoError else { finish(nil); return }
        let work = DispatchWorkItem { [weak self] in self?.finish(nil) }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + DiscoveryPolicy.wiredWait, execute: work)
    }

    private func resolveAddresses(_ host: String) {
        guard addressRef == nil else { return }
        let error = DNSServiceGetAddrInfo(&addressRef, 0, UInt32(interface.index), DNSServiceProtocol(kDNSServiceProtocol_IPv6), host,
                                        { _, flags, index, error, _, address, _, context in
            guard let context else { return }
            let resolver = Unmanaged<OwnerWiredResolver>.fromOpaque(context).takeUnretainedValue()
            guard resolver.completion != nil else { return }
            guard error == kDNSServiceErr_NoError else { resolver.finish(nil); return }
            guard flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0, let address,
                  address.pointee.sa_family == UInt8(AF_INET6) else { return }
            let ip = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
            let bytes = withUnsafeBytes(of: ip.sin6_addr) { Array($0) }
            guard OwnerWiredPolicy.addressAllowed(bytes, replyIndex: index, scopeIndex: ip.sin6_scope_id,
                interfaceIndex: UInt32(resolver.interface.index), interface: StreamClient.policyInterface(resolver.interface),
                own: StreamClient.ownAddresses()) else { return }
            var unscoped = in6_addr()
            withUnsafeMutableBytes(of: &unscoped) { $0.copyBytes(from: DiscoveryPolicy.unscoped(bytes)) }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &unscoped, &buffer, socklen_t(buffer.count)) != nil else { return }
            let target = OwnerWiredTarget(binding: resolver.binding, key: resolver.key, interface: resolver.interface,
                                          address: bytes, host: String(cString: buffer) + "%" + resolver.interface.name)
            resolver.finish(target.current() ? target : nil)
        }, Unmanaged.passUnretained(self).toOpaque())
        guard error == kDNSServiceErr_NoError, let addressRef,
              DNSServiceSetDispatchQueue(addressRef, .main) == kDNSServiceErr_NoError else { finish(nil); return }
    }

    func cancel() {
        dispatchPrecondition(condition: .onQueue(.main))
        completion = nil
        timeout?.cancel(); timeout = nil
        if let resolveRef { DNSServiceRefDeallocate(resolveRef); self.resolveRef = nil }
        if let addressRef { DNSServiceRefDeallocate(addressRef); self.addressRef = nil }
    }

    private func finish(_ target: OwnerWiredTarget?) {
        let done = completion
        cancel()
        done?(target)
    }
}

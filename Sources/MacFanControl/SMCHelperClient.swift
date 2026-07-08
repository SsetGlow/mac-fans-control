import Foundation
import ServiceManagement

enum FanControlHelperState: Equatable {
    case enabled
    case requiresApproval
    case notRegistered
    case notFound
    case unsupported
    case unknown(String)

    var title: String {
        switch self {
        case .enabled:
            return "控制程序已启用"
        case .requiresApproval:
            return "需要在系统设置中批准"
        case .notRegistered:
            return "控制程序尚未启用"
        case .notFound:
            return "没有找到控制程序"
        case .unsupported:
            return "当前 macOS 不支持此安装方式"
        case .unknown(let value):
            return "控制程序状态：\(value)"
        }
    }
}

enum FanControlHelperError: LocalizedError {
    case requiresApproval(FanControlHelperState)
    case unavailable
    case xpcTimeout
    case helperRejected(String)

    var errorDescription: String? {
        switch self {
        case .requiresApproval(let state):
            return "\(state.title)。请启用风扇控制程序后再调速。"
        case .unavailable:
            return "无法连接风扇控制程序。"
        case .xpcTimeout:
            return "风扇控制程序没有响应。"
        case .helperRejected(let message):
            return message
        }
    }
}

final class FanControlHelperClient {
    static let shared = FanControlHelperClient()

    private var connection: NSXPCConnection?

    var state: FanControlHelperState {
        if #available(macOS 13.0, *) {
            switch SMAppService.daemon(plistName: fanControlHelperPlistName).status {
            case .enabled:
                return .enabled
            case .requiresApproval:
                return .requiresApproval
            case .notRegistered:
                return .notRegistered
            case .notFound:
                return .notFound
            @unknown default:
                return .unknown(String(describing: SMAppService.daemon(plistName: fanControlHelperPlistName).status))
            }
        }
        return .unsupported
    }

    var isEnabled: Bool {
        state == .enabled
    }

    func register(force: Bool = false) throws -> FanControlHelperState {
        guard #available(macOS 13.0, *) else {
            throw FanControlHelperError.requiresApproval(.unsupported)
        }

        let service = SMAppService.daemon(plistName: fanControlHelperPlistName)
        if service.status == .enabled, !force {
            return .enabled
        }

        if force, service.status == .enabled {
            try? service.unregister()
            connection?.invalidate()
            connection = nil
        }

        do {
            try service.register()
        } catch {
            let mapped = state
            if mapped == .requiresApproval {
                return mapped
            }
            throw FanControlHelperError.helperRejected("注册风扇控制程序失败：\(error.localizedDescription)")
        }

        return state
    }

    func openLoginItems() {
        if #available(macOS 13.0, *) {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    func setAllFans(indices: [Int], rpm: Double) throws {
        try requireEnabled()
        for index in indices {
            try call { helper, completion in
                helper.setFanTarget(id: index, rpm: rpm, completion: completion)
            }
        }
    }

    func restoreAutomatic() throws {
        try requireEnabled()
        try call { helper, completion in
            helper.restoreAutomatic(completion: completion)
        }
    }

    private func requireEnabled() throws {
        let current = state
        guard current == .enabled else {
            throw FanControlHelperError.requiresApproval(current)
        }
    }

    private func helperProxy() throws -> SMCHelperProtocol {
        if connection == nil {
            let next = NSXPCConnection(machServiceName: fanControlHelperIdentifier, options: .privileged)
            next.remoteObjectInterface = NSXPCInterface(with: SMCHelperProtocol.self)
            next.invalidationHandler = { [weak self] in
                self?.connection = nil
            }
            next.resume()
            connection = next
        }

        guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ [weak self] error in
            self?.connection?.invalidate()
            self?.connection = nil
            NSLog("SMC helper XPC error: \(error.localizedDescription)")
        }) as? SMCHelperProtocol else {
            throw FanControlHelperError.unavailable
        }
        return proxy
    }

    private func call(_ body: (SMCHelperProtocol, @escaping (String?) -> Void) -> Void) throws {
        let helper = try helperProxy()
        let semaphore = DispatchSemaphore(value: 0)
        var helperError: String?

        body(helper) { errorMessage in
            helperError = errorMessage
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + 20) == .success else {
            connection?.invalidate()
            connection = nil
            throw FanControlHelperError.xpcTimeout
        }

        if let helperError, !helperError.isEmpty {
            throw FanControlHelperError.helperRejected(helperError)
        }
    }
}

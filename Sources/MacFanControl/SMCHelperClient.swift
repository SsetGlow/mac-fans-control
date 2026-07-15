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

final class FanControlHelperClient: @unchecked Sendable {
    static let shared = FanControlHelperClient()

    private let legacyDaemonPlistPath = "/Library/LaunchDaemons/\(fanControlHelperIdentifier).plist"
    private var connection: NSXPCConnection?
    private let callLock = NSLock()
    private let connectionLock = NSLock()
    private let activeCompletionLock = NSLock()
    private var activeCompletion: HelperCallCompletion?
    private var activeCompletionConnection: NSXPCConnection?

    var state: FanControlHelperState {
        // Local development builds use a root-owned LaunchDaemon because macOS
        // rejects SMAppService registration for ad-hoc signed app bundles.
        if FileManager.default.fileExists(atPath: legacyDaemonPlistPath) {
            return .enabled
        }
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
        callLock.lock()
        defer { callLock.unlock() }

        guard #available(macOS 13.0, *) else {
            throw FanControlHelperError.requiresApproval(.unsupported)
        }

        let service = SMAppService.daemon(plistName: fanControlHelperPlistName)
        if service.status == .enabled, !force {
            return .enabled
        }

        if force {
            switch service.status {
            case .enabled, .requiresApproval:
                try service.unregister()
                invalidateConnection()
            case .notRegistered, .notFound:
                break
            @unknown default:
                break
            }
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

    func installLocalDevelopmentDaemon() throws -> FanControlHelperState {
        guard let bundleURL = Bundle.main.bundleURL as URL? else {
            throw FanControlHelperError.unavailable
        }
        let helperURL = bundleURL
            .appendingPathComponent("Contents/Library/LaunchServices")
            .appendingPathComponent(fanControlHelperIdentifier)
        guard let plistURL = Bundle.main.url(
            forResource: fanControlHelperIdentifier,
            withExtension: "plist"
        ) else {
            throw FanControlHelperError.unavailable
        }

        let destination = "/Library/PrivilegedHelperTools/\(fanControlHelperIdentifier)"
        let daemonPlist = legacyDaemonPlistPath
        let shellCommand = [
            "/bin/mkdir -p /Library/PrivilegedHelperTools",
            "/bin/launchctl bootout system/\(fanControlHelperIdentifier) >/dev/null 2>&1 || true",
            "/usr/bin/install -o root -g wheel -m 755 \(shellQuote(helperURL.path)) \(shellQuote(destination))",
            "/usr/bin/install -o root -g wheel -m 644 \(shellQuote(plistURL.path)) \(shellQuote(daemonPlist))",
            "/bin/launchctl bootstrap system \(shellQuote(daemonPlist))"
        ].joined(separator: "; ")

        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "do shell script \"\(appleScriptString(shellCommand))\" with administrator privileges"
        ]
        process.standardError = errorPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw FanControlHelperError.helperRejected("安装风扇控制程序失败：\(error.localizedDescription)")
        }
        guard process.terminationStatus == 0 else {
            let detail = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw FanControlHelperError.helperRejected(detail?.isEmpty == false ? detail! : "安装风扇控制程序失败。")
        }
        invalidateConnection()
        return state
    }

    func setAllFans(indices: [Int], rpm: Double) throws {
        callLock.lock()
        defer { callLock.unlock() }
        try requireEnabled()
        for index in indices {
            try call { helper, completion in
                helper.setFanTarget(id: index, rpm: rpm, completion: completion)
            }
        }
    }

    func restoreAutomatic() throws {
        callLock.lock()
        defer { callLock.unlock() }
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

    private func helperProxy(
        errorHandler: @escaping (Error) -> Void
    ) throws -> (proxy: SMCHelperProtocol, connection: NSXPCConnection) {
        let activeConnection = connectionForCall()
        guard let proxy = activeConnection.remoteObjectProxyWithErrorHandler({ [weak self, weak activeConnection] error in
            if let activeConnection {
                self?.invalidateConnection(if: activeConnection)
            }
            NSLog("SMC helper XPC error: \(error.localizedDescription)")
            errorHandler(error)
        }) as? SMCHelperProtocol else {
            throw FanControlHelperError.unavailable
        }
        return (proxy, activeConnection)
    }

    private func call(_ body: (SMCHelperProtocol, @escaping @Sendable (String?) -> Void) -> Void) throws {
        let completion = HelperCallCompletion()
        let helper = try helperProxy { error in
            completion.finish(errorMessage: "无法连接风扇控制程序：\(error.localizedDescription)")
        }
        setActiveCompletion(completion, connection: helper.connection)
        defer { clearActiveCompletion(completion) }

        body(helper.proxy) { errorMessage in
            completion.finish(errorMessage: errorMessage)
        }

        // A healthy helper can spend roughly 15 seconds entering manual SMC mode.
        // Keep that allowance, while proxy errors and connection invalidation wake
        // the waiter immediately through HelperCallCompletion.
        guard completion.wait(timeout: .now() + 20) else {
            invalidateConnection(if: helper.connection)
            throw FanControlHelperError.xpcTimeout
        }

        if let helperError = completion.errorMessage, !helperError.isEmpty {
            throw FanControlHelperError.helperRejected(helperError)
        }
    }

    private func connectionForCall() -> NSXPCConnection {
        connectionLock.lock()
        if let connection {
            connectionLock.unlock()
            return connection
        }
        connectionLock.unlock()

        let next = NSXPCConnection(machServiceName: fanControlHelperIdentifier, options: .privileged)
        next.remoteObjectInterface = NSXPCInterface(with: SMCHelperProtocol.self)
        next.interruptionHandler = { [weak self, weak next] in
            guard let self, let next else { return }
            self.failActiveCall(for: next, message: "风扇控制程序连接已中断。")
        }
        next.invalidationHandler = { [weak self, weak next] in
            guard let self, let next, self.clearConnection(if: next) else { return }
            self.failActiveCall(for: next, message: "风扇控制程序连接已失效。")
        }

        connectionLock.lock()
        connection = next
        connectionLock.unlock()
        next.resume()
        return next
    }

    @discardableResult
    private func clearConnection(if candidate: NSXPCConnection) -> Bool {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        guard connection === candidate else { return false }
        connection = nil
        return true
    }

    private func invalidateConnection(if candidate: NSXPCConnection? = nil) {
        connectionLock.lock()
        guard candidate == nil || connection === candidate else {
            connectionLock.unlock()
            return
        }
        let staleConnection = connection
        connection = nil
        connectionLock.unlock()
        staleConnection?.invalidate()
    }

    private func setActiveCompletion(
        _ completion: HelperCallCompletion,
        connection: NSXPCConnection
    ) {
        activeCompletionLock.lock()
        activeCompletion = completion
        activeCompletionConnection = connection
        activeCompletionLock.unlock()
    }

    private func clearActiveCompletion(_ completion: HelperCallCompletion) {
        activeCompletionLock.lock()
        if activeCompletion === completion {
            activeCompletion = nil
            activeCompletionConnection = nil
        }
        activeCompletionLock.unlock()
    }

    private func failActiveCall(for connection: NSXPCConnection, message: String) {
        activeCompletionLock.lock()
        let completion = activeCompletionConnection === connection ? activeCompletion : nil
        activeCompletionLock.unlock()
        completion?.finish(errorMessage: message)
    }
}

private func shellQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}

private func appleScriptString(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

private final class HelperCallCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var didFinish = false
    private var storedErrorMessage: String?

    var errorMessage: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedErrorMessage
    }

    func finish(errorMessage: String?) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        storedErrorMessage = errorMessage
        lock.unlock()
        semaphore.signal()
    }

    func wait(timeout: DispatchTime) -> Bool {
        semaphore.wait(timeout: timeout) == .success
    }
}

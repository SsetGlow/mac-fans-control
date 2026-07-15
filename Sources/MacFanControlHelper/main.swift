import Foundation
import Security

private let mainAppBundleIdentifier = "local.mac-fan-control"
private let helperConfigurationExitCode: Int32 = 78

@main
enum MacFanControlHelperMain {
    static func main() {
        do {
            let requirement = try HelperClientAuthorization.clientCodeSigningRequirement()
            let helper = SMCHelperDaemon(clientCodeSigningRequirement: requirement)
            helper.run()
        } catch {
            NSLog("SMC helper authorization setup failed: %@", error.localizedDescription)
            exit(helperConfigurationExitCode)
        }
    }
}

final class SMCHelperDaemon: NSObject, NSXPCListenerDelegate, SMCHelperProtocol {
    private let listener: NSXPCListener
    private let queue = DispatchQueue(label: "local.mac-fan-control.smc-helper.queue")

    init(clientCodeSigningRequirement: String) {
        listener = NSXPCListener(machServiceName: fanControlHelperIdentifier)
        super.init()
        listener.setConnectionCodeSigningRequirement(clientCodeSigningRequirement)
    }

    func run() {
        listener.delegate = self
        listener.resume()
        RunLoop.current.run()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: SMCHelperProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func setFanTarget(id: Int, rpm: Double, completion: @escaping @Sendable (String?) -> Void) {
        queue.async {
            do {
                guard rpm.isFinite else {
                    throw SMCHelperRequestError.nonFiniteRPM
                }
                guard Self.absoluteRPMRange.contains(rpm) else {
                    throw SMCHelperRequestError.unsafeRPM(rpm)
                }

                let smc = try SMCClient()
                let fanCount = max(0, try smc.fanCount())
                guard id >= 0, id < fanCount else {
                    throw SMCHelperRequestError.invalidFanIndex(id, fanCount: fanCount)
                }

                let prefix = "F\(id)"
                let minimum = try? smc.readDouble("\(prefix)Mn")
                let maximum = try? smc.readDouble("\(prefix)Mx")
                if let minimum, minimum.isFinite, rpm < minimum {
                    throw SMCHelperRequestError.outsideHardwareRange(rpm, minimum: minimum, maximum: maximum)
                }
                if let maximum, maximum.isFinite, rpm > maximum {
                    throw SMCHelperRequestError.outsideHardwareRange(rpm, minimum: minimum, maximum: maximum)
                }

                try smc.setFan(index: id, rpm: rpm)
                completion(nil)
            } catch {
                completion(error.localizedDescription)
            }
        }
    }

    func restoreAutomatic(completion: @escaping @Sendable (String?) -> Void) {
        queue.async {
            do {
                let smc = try SMCClient()
                try smc.restoreAutomaticFanControl()
                completion(nil)
            } catch {
                completion(error.localizedDescription)
            }
        }
    }

    private static let absoluteRPMRange = 500.0...20_000.0
}

private enum HelperClientAuthorization {
    static func clientCodeSigningRequirement() throws -> String {
        let helperCode = try currentHelperCode()
        guard let helperIdentity = try? signingIdentity(for: helperCode, component: "helper") else {
            return try localDevelopmentClientRequirement()
        }

        guard helperIdentity.identifier == fanControlHelperIdentifier else {
            throw HelperAuthorizationError(
                "helper signing identifier mismatch: expected \(fanControlHelperIdentifier), got \(helperIdentity.identifier)"
            )
        }
        guard isValidTeamIdentifier(helperIdentity.teamIdentifier) else {
            throw HelperAuthorizationError("helper has no valid Apple Team Identifier")
        }

        let expectedClientRequirement = "identifier \"\(mainAppBundleIdentifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(helperIdentity.teamIdentifier)\""
        let expectedRequirement = try makeRequirement(expectedClientRequirement)
        let appCode = try containingAppCode(for: helperCode)

        let strictFlags = SecCSFlags(
            rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode
        )
        try checkStatus(
            SecStaticCodeCheckValidity(appCode, strictFlags, expectedRequirement),
            operation: "validate containing app signature"
        )

        let appIdentity = try signingIdentity(for: appCode, component: "main app")
        guard appIdentity.identifier == mainAppBundleIdentifier else {
            throw HelperAuthorizationError(
                "main app signing identifier mismatch: expected \(mainAppBundleIdentifier), got \(appIdentity.identifier)"
            )
        }
        guard appIdentity.teamIdentifier == helperIdentity.teamIdentifier else {
            throw HelperAuthorizationError("main app and helper Team Identifiers do not match")
        }

        let designatedRequirement = try copyDesignatedRequirementString(for: appCode)
        let combinedRequirement = "(\(designatedRequirement)) and (\(expectedClientRequirement))"
        _ = try makeRequirement(combinedRequirement)
        return combinedRequirement
    }

    private static func localDevelopmentClientRequirement() throws -> String {
        let appURL = URL(fileURLWithPath: "/Applications/Mac Fan Control.app")
        var appCode: SecStaticCode?
        try checkStatus(
            SecStaticCodeCreateWithPath(appURL as CFURL, [], &appCode),
            operation: "open local development app code"
        )
        guard let appCode else {
            throw HelperAuthorizationError("Security.framework returned no local development app code")
        }

        try checkStatus(
            SecStaticCodeCheckValidity(appCode, SecCSFlags(rawValue: kSecCSStrictValidate), nil),
            operation: "validate local development app signature"
        )
        guard try signingIdentifier(for: appCode) == mainAppBundleIdentifier else {
            throw HelperAuthorizationError("local development app signing identifier mismatch")
        }

        // An ad-hoc signature has no Apple Team Identifier. Its designated
        // requirement is an exact cdhash, so only this installed app build can
        // connect to the root helper.
        let designatedRequirement = try copyDesignatedRequirementString(for: appCode)
        let requirement = "(\(designatedRequirement)) and identifier \"\(mainAppBundleIdentifier)\""
        _ = try makeRequirement(requirement)
        return requirement
    }

    private static func currentHelperCode() throws -> SecStaticCode {
        var dynamicCode: SecCode?
        try checkStatus(SecCodeCopySelf([], &dynamicCode), operation: "copy running helper code")
        guard let dynamicCode else {
            throw HelperAuthorizationError("Security.framework returned no running helper code")
        }

        try checkStatus(
            SecCodeCheckValidity(dynamicCode, [], nil),
            operation: "validate running helper code"
        )

        var staticCode: SecStaticCode?
        try checkStatus(
            SecCodeCopyStaticCode(dynamicCode, [], &staticCode),
            operation: "copy helper static code"
        )
        guard let staticCode else {
            throw HelperAuthorizationError("Security.framework returned no helper static code")
        }
        return staticCode
    }

    private static func containingAppCode(for helperCode: SecStaticCode) throws -> SecStaticCode {
        var helperURL: CFURL?
        try checkStatus(
            SecCodeCopyPath(helperCode, [], &helperURL),
            operation: "copy helper executable path"
        )
        guard var appURL = helperURL as URL? else {
            throw HelperAuthorizationError("Security.framework returned no helper executable path")
        }

        // Contents/Library/LaunchServices/<helper> -> containing .app bundle.
        for _ in 0..<4 {
            appURL.deleteLastPathComponent()
        }
        guard appURL.pathExtension.lowercased() == "app" else {
            throw HelperAuthorizationError("helper is not inside the expected app bundle layout")
        }

        var appCode: SecStaticCode?
        try checkStatus(
            SecStaticCodeCreateWithPath(appURL as CFURL, [], &appCode),
            operation: "open containing app code"
        )
        guard let appCode else {
            throw HelperAuthorizationError("Security.framework returned no containing app code")
        }
        return appCode
    }

    private static func signingIdentity(for code: SecStaticCode, component: String) throws -> CodeIdentity {
        var information: CFDictionary?
        try checkStatus(
            SecCodeCopySigningInformation(
                code,
                SecCSFlags(rawValue: kSecCSSigningInformation),
                &information
            ),
            operation: "read \(component) signing information"
        )
        guard let dictionary = information as? [String: Any],
              let identifier = dictionary[kSecCodeInfoIdentifier as String] as? String,
              let teamIdentifier = dictionary[kSecCodeInfoTeamIdentifier as String] as? String else {
            throw HelperAuthorizationError("\(component) is not signed with an Apple team identity")
        }
        return CodeIdentity(identifier: identifier, teamIdentifier: teamIdentifier)
    }

    private static func signingIdentifier(for code: SecStaticCode) throws -> String {
        var information: CFDictionary?
        try checkStatus(
            SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information),
            operation: "read signing identifier"
        )
        guard let dictionary = information as? [String: Any],
              let identifier = dictionary[kSecCodeInfoIdentifier as String] as? String else {
            throw HelperAuthorizationError("code has no signing identifier")
        }
        return identifier
    }

    private static func copyDesignatedRequirementString(for code: SecStaticCode) throws -> String {
        var requirement: SecRequirement?
        try checkStatus(
            SecCodeCopyDesignatedRequirement(code, [], &requirement),
            operation: "copy main app designated requirement"
        )
        guard let requirement else {
            throw HelperAuthorizationError("main app has no designated requirement")
        }

        var text: CFString?
        try checkStatus(
            SecRequirementCopyString(requirement, [], &text),
            operation: "serialize main app designated requirement"
        )
        guard let text = text as String?, !text.isEmpty else {
            throw HelperAuthorizationError("main app designated requirement is empty")
        }
        return text
    }

    private static func makeRequirement(_ text: String) throws -> SecRequirement {
        var requirement: SecRequirement?
        try checkStatus(
            SecRequirementCreateWithString(text as CFString, [], &requirement),
            operation: "compile client code-signing requirement"
        )
        guard let requirement else {
            throw HelperAuthorizationError("Security.framework returned no code-signing requirement")
        }
        return requirement
    }

    private static func isValidTeamIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 64 && value.unicodeScalars.allSatisfy {
            (65...90).contains($0.value) || (48...57).contains($0.value)
        }
    }

    private static func checkStatus(_ status: OSStatus, operation: String) throws {
        guard status == errSecSuccess else {
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            throw HelperAuthorizationError("\(operation) failed: \(detail) (\(status))")
        }
    }
}

private struct CodeIdentity {
    let identifier: String
    let teamIdentifier: String
}

private struct HelperAuthorizationError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

private enum SMCHelperRequestError: LocalizedError {
    case invalidFanIndex(Int, fanCount: Int)
    case nonFiniteRPM
    case unsafeRPM(Double)
    case outsideHardwareRange(Double, minimum: Double?, maximum: Double?)

    var errorDescription: String? {
        switch self {
        case .invalidFanIndex(let index, let fanCount):
            return "风扇编号 \(index) 无效；当前检测到 \(fanCount) 个风扇。"
        case .nonFiniteRPM:
            return "目标转速必须是有限数值。"
        case .unsafeRPM(let rpm):
            return "目标转速 \(String(format: "%g", rpm)) rpm 超出安全范围。"
        case .outsideHardwareRange(let rpm, let minimum, let maximum):
            let minimumText = minimum.flatMap { $0.isFinite ? String(format: "%.0f", $0) : nil } ?? "未知"
            let maximumText = maximum.flatMap { $0.isFinite ? String(format: "%.0f", $0) : nil } ?? "未知"
            return "目标转速 \(Int(rpm.rounded())) rpm 超出硬件范围 \(minimumText)-\(maximumText) rpm。"
        }
    }
}

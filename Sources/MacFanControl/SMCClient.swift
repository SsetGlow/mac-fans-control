import Foundation
import IOKit

struct FanReading: Identifiable {
    let index: Int
    let currentRPM: Double?
    let minimumRPM: Double?
    let maximumRPM: Double?
    let targetRPM: Double?
    let isManual: Bool

    var id: Int { index }
}

struct TemperatureReading: Identifiable {
    let key: String
    let label: String
    let group: TemperatureScope
    let celsius: Double

    var id: String { key }
}

struct HardwareSnapshot {
    let sampledAt: Date
    let fans: [FanReading]
    let temperatures: [TemperatureReading]
    let errorMessage: String?

    static let empty = HardwareSnapshot(sampledAt: Date(), fans: [], temperatures: [], errorMessage: nil)

    var maximumTemperature: Double? {
        temperatures.map(\.celsius).max()
    }

    func maximumTemperature(for scope: TemperatureScope) -> Double? {
        switch scope {
        case .all:
            return maximumTemperature
        case .cpu, .gpu:
            return temperatures.filter { $0.group == scope }.map(\.celsius).max()
        }
    }
}

enum TemperatureScope: String, CaseIterable, Identifiable {
    case all
    case cpu
    case gpu

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        }
    }
}

enum SMCClientError: LocalizedError {
    case serviceUnavailable
    case noFansAvailable
    case openFailed(kern_return_t)
    case callFailed(kern_return_t)
    case smcRejected(key: String, result: UInt8)
    case keyUnavailable(String)
    case invalidWriteSize(key: String, expected: UInt32, actual: Int)

    var errorDescription: String? {
        switch self {
        case .serviceUnavailable:
            return "没有找到 AppleSMC 服务。这台 Mac 可能不暴露传统 SMC 传感器。"
        case .noFansAvailable:
            return "没有可控制的风扇。"
        case .openFailed(let code):
            return "打开 AppleSMC 失败：\(code)"
        case .callFailed(let code):
            return "调用 AppleSMC 失败：\(code)"
        case .smcRejected(let key, let result):
            return "SMC 拒绝访问 \(key)：\(result)"
        case .keyUnavailable(let key):
            return "SMC 键不存在：\(key)"
        case .invalidWriteSize(let key, let expected, let actual):
            return "写入 \(key) 的数据长度不匹配，需要 \(expected) 字节，实际 \(actual) 字节。"
        }
    }
}

final class HardwareMonitor {
    private let smc: SMCClient
    private var temperatureKeys: [String]?

    init() throws {
        smc = try SMCClient()
    }

    func snapshot() -> HardwareSnapshot {
        do {
            let fans = try readFans()
            let temperatures = try readTemperatures()
            let emptyMessage = fans.isEmpty && temperatures.isEmpty
                ? "已连接 SMC，但没有读到风扇或温度传感器。"
                : nil
            return HardwareSnapshot(
                sampledAt: Date(),
                fans: fans,
                temperatures: temperatures,
                errorMessage: emptyMessage
            )
        } catch {
            return HardwareSnapshot(
                sampledAt: Date(),
                fans: (try? readFans()) ?? [],
                temperatures: (try? readTemperatures()) ?? [],
                errorMessage: error.localizedDescription
            )
        }
    }

    func setAllFans(targetRPM: Double) throws {
        let fans = try readFans()
        guard !fans.isEmpty else {
            throw SMCClientError.noFansAvailable
        }
        for fan in fans {
            try smc.setFan(index: fan.index, rpm: targetRPM)
        }
    }

    func setFan(index: Int, targetRPM: Double) throws {
        let fans = try readFans()
        guard fans.contains(where: { $0.index == index }) else {
            throw SMCClientError.noFansAvailable
        }
        try smc.setFan(index: index, rpm: targetRPM)
    }

    func restoreAutomaticControl() throws {
        try smc.restoreAutomaticFanControl()
    }

    private func readFans() throws -> [FanReading] {
        let count = max(0, try smc.fanCount())
        guard count > 0 else { return [] }
        return (0..<count).map { index in
            let prefix = "F\(index)"
            return FanReading(
                index: index,
                currentRPM: try? smc.readDouble("\(prefix)Ac"),
                minimumRPM: try? smc.readDouble("\(prefix)Mn"),
                maximumRPM: try? smc.readDouble("\(prefix)Mx"),
                targetRPM: try? smc.readDouble("\(prefix)Tg"),
                isManual: (try? smc.isFanInManualMode(index: index)) ?? false
            )
        }
    }

    private func readTemperatures() throws -> [TemperatureReading] {
        if temperatureKeys == nil {
            temperatureKeys = smc.discoverTemperatureKeys()
        }

        let hid = AppleSiliconTemperatureReader.read()
        let keys = temperatureKeys ?? []
        let discovered = keys.compactMap { key -> TemperatureReading? in
            guard let value = try? smc.readDouble(key), value > -20, value < 130 else {
                return nil
            }
            let group = classifyTemperatureKey(key)
            guard group == .cpu || group == .gpu || key.hasPrefix("T") else {
                return nil
            }
            return TemperatureReading(key: key, label: label(for: key, group: group), group: group, celsius: value)
        }
        let battery = readBatteryTemperatures()

        if !discovered.isEmpty {
            return sortedTemperatures(uniqueTemperatures(discovered + hid + battery))
        }

        let fallback = fallbackTemperatureKeys().compactMap { key -> TemperatureReading? in
            guard let value = try? smc.readDouble(key), value > -20, value < 130 else { return nil }
            let group = classifyTemperatureKey(key)
            return TemperatureReading(key: key, label: label(for: key, group: group), group: group, celsius: value)
        }
        return sortedTemperatures(uniqueTemperatures(fallback + hid + battery))
    }

    private func sortedTemperatures(_ readings: [TemperatureReading]) -> [TemperatureReading] {
        readings.sorted { lhs, rhs in
                if lhs.group.rawValue == rhs.group.rawValue {
                    return lhs.key < rhs.key
                }
                return lhs.group.rawValue < rhs.group.rawValue
        }
    }

    private func fallbackTemperatureKeys() -> [String] {
        [
            "TC0P", "TC0E", "TC0F", "TC0D", "TC0H", "TC0C", "TC1C", "TC2C",
            "TG0P", "TG0D", "TG0H", "TG0F", "TG1C", "TG2C",
            "TA0P", "TB0T", "TM0P", "TN0D"
        ]
    }

    private func classifyTemperatureKey(_ key: String) -> TemperatureScope {
        if key.hasPrefix("TC") || key.hasPrefix("Tp") || key.hasPrefix("Te") { return .cpu }
        if key.hasPrefix("TG") || key.hasPrefix("Tg") || key == "TRDX" { return .gpu }
        return .all
    }

    private func label(for key: String, group: TemperatureScope) -> String {
        switch group {
        case .cpu: return "CPU \(key)"
        case .gpu: return "GPU \(key)"
        case .all: return "传感器 \(key)"
        }
    }

    private func readBatteryTemperatures() -> [TemperatureReading] {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return [] }
        defer { IOObjectRelease(service) }

        var readings: [TemperatureReading] = []
        if let temperature = readRegistryTemperature(service: service, key: "Temperature") {
            readings.append(TemperatureReading(key: "BAT0", label: "电池", group: .all, celsius: temperature))
        }
        if let virtualTemperature = readRegistryTemperature(service: service, key: "VirtualTemperature") {
            readings.append(TemperatureReading(key: "BATV", label: "电池 Virtual", group: .all, celsius: virtualTemperature))
        }
        return readings
    }

    private func readRegistryTemperature(service: io_registry_entry_t, key: String) -> Double? {
        guard let rawValue = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber else {
            return nil
        }

        let value = rawValue.doubleValue
        let normalized: Double
        if value > 2_000 {
            normalized = value / 100.0
        } else if value > 200 {
            normalized = value / 10.0
        } else {
            normalized = value
        }
        guard normalized > -20, normalized < 130 else { return nil }
        return normalized
    }

    private func uniqueTemperatures(_ readings: [TemperatureReading]) -> [TemperatureReading] {
        var seen = Set<String>()
        return readings.filter { reading in
            seen.insert(reading.key).inserted
        }
    }
}

private struct SMCValue {
    let key: String
    let dataSize: UInt32
    let dataType: String
    var bytes: [UInt8]

    var doubleValue: Double? {
        switch dataType {
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            let integer = Double(Int8(bitPattern: bytes[0]))
            let fraction = Double(bytes[1]) / 256.0
            return integer + fraction
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            let raw = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            return Double(raw) / 4.0
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let raw = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: raw))
        case "ui8 ", "ui8", "ui16", "ui32":
            return uintValue.map(Double.init)
        default:
            return nil
        }
    }

    var uintValue: UInt32? {
        guard !bytes.isEmpty else { return nil }
        return bytes.reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
    }
}

private typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

private struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPowerLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCKeyInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

private struct SMCKeyData {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPowerLimitData()
    var keyInfo = SMCKeyInfo()
    var keyInfoPadding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = zeroSMCBytes()
}

private enum SMCCommand: UInt8 {
    case readBytes = 5
    case writeBytes = 6
    case readIndex = 8
    case readKeyInfo = 9
}

private let smcKernelIndex: UInt32 = 2

final class SMCClient {
    private var connection: io_connect_t = 0
    private var fanModeKeyIsLowercase: Bool?

    init() throws {
        let candidates = ["AppleSMC", "AppleSMCKeysEndpoint"]
        var service: io_service_t = 0
        for candidate in candidates {
            service = candidate.withCString { pointer in
                IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(pointer))
            }
            if service != 0 {
                break
            }
        }
        guard service != 0 else {
            throw SMCClientError.serviceUnavailable
        }
        defer { IOObjectRelease(service) }

        var opened: io_connect_t = 0
        let result = IOServiceOpen(service, mach_task_self_, 0, &opened)
        guard result == KERN_SUCCESS else {
            throw SMCClientError.openFailed(result)
        }
        connection = opened
    }

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
    }

    func fanCount() throws -> Int {
        if let count = try? readUInt("FNum") {
            return Int(count)
        }

        var count = 0
        for index in 0..<8 {
            if (try? readValue("F\(index)Ac")) != nil {
                count += 1
            }
        }
        return count
    }

    func readDouble(_ key: String) throws -> Double {
        guard let value = try readValue(key).doubleValue else {
            throw SMCClientError.keyUnavailable(key)
        }
        return value
    }

    func readUInt(_ key: String) throws -> UInt32 {
        guard let value = try readValue(key).uintValue else {
            throw SMCClientError.keyUnavailable(key)
        }
        return value
    }

    func discoverTemperatureKeys() -> [String] {
        guard let count = try? readUInt("#KEY"), count > 0 else {
            return []
        }

        var keys: [String] = []
        for index in 0..<min(count, 4_096) {
            guard let key = try? readKey(at: index), key.hasPrefix("T") else { continue }
            guard let info = try? readKeyInfo(key), fourCharString(info.dataType) == "sp78" else { continue }
            keys.append(key)
        }
        return keys
    }

    func setFan(index: Int, rpm: Double) throws {
        let prefix = "F\(index)"
        let minimum = (try? readDouble("\(prefix)Mn")) ?? 1_200
        let maximum = (try? readDouble("\(prefix)Mx")) ?? 6_500
        let clamped = max(minimum, min(maximum, rpm))
        try setFanManualMode(index: index, enabled: true)
        try writeFanTarget(index: index, rpm: clamped)
    }

    func restoreAutomaticFanControl() throws {
        var restored = false

        if var testMode = try? readValue("Ftst"), !testMode.bytes.isEmpty {
            testMode.bytes[0] = 0
            try writeKey(testMode.key, bytes: Array(testMode.bytes.prefix(Int(testMode.dataSize))))
            restored = true
        }

        let count = max(0, (try? fanCount()) ?? 0)
        for index in 0..<count {
            if (try? setFanManualMode(index: index, enabled: false)) != nil {
                restored = true
            }
        }

        if var legacyMode = try? readValue("FS! ") {
            legacyMode.bytes = Array(repeating: 0, count: max(legacyMode.bytes.count, Int(legacyMode.dataSize)))
            try writeKey(legacyMode.key, bytes: Array(legacyMode.bytes.prefix(Int(legacyMode.dataSize))))
            restored = true
        }

        if !restored {
            throw SMCClientError.keyUnavailable("Ftst / F*Md / FS! ")
        }
    }

    private func readValue(_ key: String) throws -> SMCValue {
        let info = try readKeyInfo(key)
        var input = SMCKeyData()
        input.key = fourCharCode(key)
        input.keyInfo = info
        input.data8 = SMCCommand.readBytes.rawValue

        let output = try call(input: input, key: key)
        guard output.result == 0 else {
            throw SMCClientError.smcRejected(key: key, result: output.result)
        }

        let count = Int(info.dataSize)
        return SMCValue(
            key: key,
            dataSize: info.dataSize,
            dataType: fourCharString(info.dataType),
            bytes: bytesArray(output.bytes, count: count)
        )
    }

    private func readKeyInfo(_ key: String) throws -> SMCKeyInfo {
        var input = SMCKeyData()
        input.key = fourCharCode(key)
        input.data8 = SMCCommand.readKeyInfo.rawValue

        let output = try call(input: input, key: key)
        guard output.result == 0, output.keyInfo.dataSize > 0 else {
            throw SMCClientError.smcRejected(key: key, result: output.result)
        }
        return output.keyInfo
    }

    private func readKey(at index: UInt32) throws -> String {
        var input = SMCKeyData()
        input.data8 = SMCCommand.readIndex.rawValue
        input.data32 = index

        let output = try call(input: input, key: "#\(index)")
        guard output.result == 0 else {
            throw SMCClientError.smcRejected(key: "#\(index)", result: output.result)
        }
        return fourCharString(output.key)
    }

    private func writeKey(_ key: String, bytes: [UInt8]) throws {
        let info = try readKeyInfo(key)
        guard bytes.count == Int(info.dataSize) else {
            throw SMCClientError.invalidWriteSize(key: key, expected: info.dataSize, actual: bytes.count)
        }

        var input = SMCKeyData()
        input.key = fourCharCode(key)
        input.keyInfo = info
        input.data8 = SMCCommand.writeBytes.rawValue
        input.bytes = tuple(from: bytes)

        let output = try call(input: input, key: key)
        guard output.result == 0 else {
            throw SMCClientError.smcRejected(key: key, result: output.result)
        }
    }

    func isFanInManualMode(index: Int) throws -> Bool {
        if let modeKey = fanModeKey(index), let mode = try? readUInt(modeKey) {
            return mode != 0
        }

        let legacyMask = try readUInt("FS! ")
        return (legacyMask & (1 << UInt32(index))) != 0
    }

    private func setFanManualMode(index: Int, enabled: Bool) throws {
        if let modeKey = fanModeKey(index), var value = try? readValue(modeKey), !value.bytes.isEmpty {
            value.bytes[0] = enabled ? 1 : 0
            do {
                try writeKey(modeKey, bytes: Array(value.bytes.prefix(Int(value.dataSize))))
                return
            } catch {
                if !enabled {
                    throw error
                }
            }

            if var testMode = try? readValue("Ftst"), !testMode.bytes.isEmpty {
                testMode.bytes[0] = 1
                try writeKeyWithRetry(
                    testMode.key,
                    bytes: Array(testMode.bytes.prefix(Int(testMode.dataSize))),
                    attempts: 40,
                    delayMicroseconds: 50_000
                )
                usleep(3_000_000)

                value.bytes[0] = 1
                try writeKeyWithRetry(
                    modeKey,
                    bytes: Array(value.bytes.prefix(Int(value.dataSize))),
                    attempts: 120,
                    delayMicroseconds: 100_000
                )
                return
            }

            throw SMCClientError.smcRejected(key: modeKey, result: 1)
        }

        var legacyMask = (try? readUInt("FS! ")) ?? 0
        if enabled {
            legacyMask |= 1 << UInt32(index)
        } else {
            legacyMask &= ~(1 << UInt32(index))
        }
        try writeKey("FS! ", bytes: encodeUInt16(UInt16(legacyMask)))
    }

    private func fanModeKey(_ index: Int) -> String? {
        if fanModeKeyIsLowercase == nil {
            fanModeKeyIsLowercase = (try? readValue("F0md")) != nil
        }

        if fanModeKeyIsLowercase == true {
            return "F\(index)md"
        }

        let upper = "F\(index)Md"
        if (try? readValue(upper)) != nil {
            return upper
        }
        return nil
    }

    private func writeFanTarget(index: Int, rpm: Double) throws {
        let key = "F\(index)Tg"
        let value = try readValue(key)

        switch value.dataType {
        case "flt ":
            try writeKey(key, bytes: encodeFloat32(rpm))
        case "fpe2":
            try writeKey(key, bytes: encodeFPE2(rpm))
        default:
            throw SMCClientError.keyUnavailable("\(key) (\(value.dataType))")
        }
    }

    private func writeKeyWithRetry(_ key: String, bytes: [UInt8], attempts: Int, delayMicroseconds: useconds_t) throws {
        var lastError: Error?
        for attempt in 0..<attempts {
            do {
                try writeKey(key, bytes: bytes)
                return
            } catch {
                lastError = error
                if attempt < attempts - 1 {
                    usleep(delayMicroseconds)
                }
            }
        }
        throw lastError ?? SMCClientError.smcRejected(key: key, result: 1)
    }

    private func call(input: SMCKeyData, key: String) throws -> SMCKeyData {
        var input = input
        var output = SMCKeyData()
        var outputSize = MemoryLayout<SMCKeyData>.stride

        let result = Swift.withUnsafeBytes(of: &input) { inputBuffer in
            Swift.withUnsafeMutableBytes(of: &output) { outputBuffer in
                IOConnectCallStructMethod(
                    connection,
                    smcKernelIndex,
                    inputBuffer.baseAddress,
                    inputBuffer.count,
                    outputBuffer.baseAddress,
                    &outputSize
                )
            }
        }

        guard result == KERN_SUCCESS else {
            throw SMCClientError.callFailed(result)
        }
        return output
    }
}

private func zeroSMCBytes() -> SMCBytes {
    (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    )
}

private func tuple(from bytes: [UInt8]) -> SMCBytes {
    var padded = Array(bytes.prefix(32))
    if padded.count < 32 {
        padded.append(contentsOf: Array(repeating: 0, count: 32 - padded.count))
    }

    return (
        padded[0], padded[1], padded[2], padded[3], padded[4], padded[5], padded[6], padded[7],
        padded[8], padded[9], padded[10], padded[11], padded[12], padded[13], padded[14], padded[15],
        padded[16], padded[17], padded[18], padded[19], padded[20], padded[21], padded[22], padded[23],
        padded[24], padded[25], padded[26], padded[27], padded[28], padded[29], padded[30], padded[31]
    )
}

private func bytesArray(_ bytes: SMCBytes, count: Int) -> [UInt8] {
    Swift.withUnsafeBytes(of: bytes) { raw in
        Array(raw.prefix(max(0, min(count, 32))))
    }
}

private func fourCharCode(_ string: String) -> UInt32 {
    var result: UInt32 = 0
    let bytes = Array(string.utf8.prefix(4))
    let padded = bytes + Array(repeating: UInt8(ascii: " "), count: max(0, 4 - bytes.count))
    for byte in padded {
        result = (result << 8) | UInt32(byte)
    }
    return result
}

private func fourCharString(_ code: UInt32) -> String {
    let bytes = [
        UInt8((code >> 24) & 0xff),
        UInt8((code >> 16) & 0xff),
        UInt8((code >> 8) & 0xff),
        UInt8(code & 0xff)
    ]
    return String(bytes: bytes, encoding: .macOSRoman) ?? ""
}

private func encodeFPE2(_ value: Double) -> [UInt8] {
    let raw = UInt16(max(0, min(Double(UInt16.max), value * 4.0)).rounded())
    return [UInt8((raw >> 8) & 0xff), UInt8(raw & 0xff)]
}

private func encodeUInt16(_ value: UInt16) -> [UInt8] {
    [UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
}

private func encodeFloat32(_ value: Double) -> [UInt8] {
    var raw = Float(value).bitPattern.littleEndian
    return withUnsafeBytes(of: &raw) { Array($0) }
}

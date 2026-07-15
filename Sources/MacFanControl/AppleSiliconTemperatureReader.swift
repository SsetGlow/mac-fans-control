import Foundation
import IOKit.hidsystem

private typealias IOHIDEventRef = CFTypeRef

@_silgen_name("IOHIDEventSystemClientCreate")
private func HIDEventSystemClientCreate(_ allocator: CFAllocator?) -> IOHIDEventSystemClient

@_silgen_name("IOHIDEventSystemClientSetMatching")
private func HIDEventSystemClientSetMatching(_ client: IOHIDEventSystemClient, _ matching: CFDictionary) -> Int32

@_silgen_name("IOHIDServiceClientCopyEvent")
private func HIDServiceClientCopyEvent(
    _ service: IOHIDServiceClient,
    _ type: Int64,
    _ options: Int32,
    _ timeout: Int64
) -> IOHIDEventRef?

@_silgen_name("IOHIDServiceClientCopyProperty")
private func HIDServiceClientCopyProperty(_ service: IOHIDServiceClient, _ property: CFString) -> CFTypeRef?

@_silgen_name("IOHIDEventGetFloatValue")
private func HIDEventGetFloatValue(_ event: IOHIDEventRef, _ field: Int32) -> Double

enum AppleSiliconTemperatureReader {
    private static let appleVendorPage = 0xff00
    private static let temperatureUsage = 0x0005
    private static let temperatureEventType: Int64 = 15
    private static let temperatureField = Int32(temperatureEventType << 16)
    private static let cache = HIDTemperatureSensorCache()

    static func read() -> [TemperatureReading] {
        cache.lock.lock()
        defer { cache.lock.unlock() }

        var readingsByProduct: [String: TemperatureReading] = [:]
        for sensor in cachedSensors() {
            guard let value = copyTemperature(from: sensor.service), isValidTemperature(value) else {
                continue
            }

            let reading = TemperatureReading(
                key: "HID-\(sensor.product)",
                label: label(for: sensor.product, group: sensor.group),
                group: sensor.group,
                celsius: value
            )

            // IOHID can expose the same named sensor through several services.
            // Keep the hottest value so the dashboard stays conservative without
            // rendering a grid full of visually identical cards.
            if let existing = readingsByProduct[sensor.product], existing.celsius >= value {
                continue
            }
            readingsByProduct[sensor.product] = reading
        }

        return Array(readingsByProduct.values)
    }

    private static func cachedSensors() -> [HIDTemperatureSensor] {
        if let sensors = cache.sensors {
            return sensors
        }

        let client = HIDEventSystemClientCreate(kCFAllocatorDefault)
        cache.client = client

        let match = [
            "PrimaryUsagePage": appleVendorPage,
            "PrimaryUsage": temperatureUsage
        ] as CFDictionary
        _ = HIDEventSystemClientSetMatching(client, match)

        guard let services = IOHIDEventSystemClientCopyServices(client) as? [Any] else {
            cache.sensors = []
            return []
        }

        let discovered = services.compactMap { rawService -> HIDTemperatureSensor? in
            let service = rawService as! IOHIDServiceClient
            guard let product = copyProductName(from: service),
                  let group = classify(product: product) else {
                return nil
            }

            return HIDTemperatureSensor(
                product: product,
                group: group,
                service: service
            )
        }

        cache.sensors = discovered
        return discovered
    }

    private static func copyProductName(from service: IOHIDServiceClient) -> String? {
        guard let productRef = HIDServiceClientCopyProperty(service, "Product" as CFString) else {
            return nil
        }
        return productRef as? String
    }

    private static func copyTemperature(from service: IOHIDServiceClient) -> Double? {
        guard let event = HIDServiceClientCopyEvent(service, temperatureEventType, 0, 0) else {
            return nil
        }
        return HIDEventGetFloatValue(event, temperatureField)
    }

    private static func classify(product: String) -> TemperatureScope? {
        if product.hasPrefix("PMU tdie")
            || product.hasPrefix("pACC")
            || product.hasPrefix("eACC")
            || product.hasPrefix("sACC")
            || product.hasPrefix("mACC")
            || product.localizedCaseInsensitiveContains("CPU") {
            return .cpu
        }

        if product.localizedCaseInsensitiveContains("GPU")
            || (product.hasPrefix("PMU TP") && product.hasSuffix("g")) {
            return .gpu
        }

        return nil
    }

    private static func label(for product: String, group: TemperatureScope) -> String {
        switch group {
        case .cpu:
            return "CPU \(product)"
        case .gpu:
            return "GPU \(product)"
        case .all:
            return product
        }
    }

    private static func isValidTemperature(_ value: Double) -> Bool {
        value > -20 && value < 150
    }
}

private struct HIDTemperatureSensor {
    let product: String
    let group: TemperatureScope
    let service: IOHIDServiceClient
}

private final class HIDTemperatureSensorCache: @unchecked Sendable {
    let lock = NSLock()
    var client: IOHIDEventSystemClient?
    var sensors: [HIDTemperatureSensor]?
}

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
    private static var client: IOHIDEventSystemClient?
    private static var sensors: [HIDTemperatureSensor]?

    static func read() -> [TemperatureReading] {
        var readings: [TemperatureReading] = []
        for sensor in cachedSensors() {
            guard let value = copyTemperature(from: sensor.service), isValidTemperature(value) else {
                continue
            }

            readings.append(TemperatureReading(
                key: sensor.key,
                label: label(for: sensor.product, group: sensor.group),
                group: sensor.group,
                celsius: value
            ))
        }

        return readings
    }

    private static func cachedSensors() -> [HIDTemperatureSensor] {
        if let sensors {
            return sensors
        }

        let client = HIDEventSystemClientCreate(kCFAllocatorDefault)
        self.client = client

        let match = [
            "PrimaryUsagePage": appleVendorPage,
            "PrimaryUsage": temperatureUsage
        ] as CFDictionary
        _ = HIDEventSystemClientSetMatching(client, match)

        guard let services = IOHIDEventSystemClientCopyServices(client) as? [Any] else {
            sensors = []
            return []
        }

        let discovered = services.enumerated().compactMap { index, rawService -> HIDTemperatureSensor? in
            let service = rawService as! IOHIDServiceClient
            guard let product = copyProductName(from: service),
                  let group = classify(product: product) else {
                return nil
            }

            return HIDTemperatureSensor(
                key: "HID\(index)-\(product)",
                product: product,
                group: group,
                service: service
            )
        }

        sensors = discovered
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
    let key: String
    let product: String
    let group: TemperatureScope
    let service: IOHIDServiceClient
}

import AppKit
import Foundation

@main
enum MacFanControlMain {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--probe") {
            do {
                let monitor = try HardwareMonitor()
                let snapshot = monitor.snapshot()
                print("Fans:")
                if snapshot.fans.isEmpty {
                    print("  none")
                } else {
                    for fan in snapshot.fans {
                        print("  Fan \(fan.index): current=\(formatRPM(fan.currentRPM)) min=\(formatRPM(fan.minimumRPM)) max=\(formatRPM(fan.maximumRPM)) mode=\(fan.isManual ? "manual" : "auto")")
                    }
                }

                print("Temperatures:")
                if snapshot.temperatures.isEmpty {
                    print("  none")
                } else {
                    for sensor in snapshot.temperatures {
                        print("  \(sensor.key) \(sensor.label): \(formatTemperature(sensor.celsius))")
                    }
                }

                if let error = snapshot.errorMessage {
                    print("Error: \(error)")
                    exit(2)
                }
                exit(0)
            } catch {
                print("Error: \(error.localizedDescription)")
                exit(2)
            }
        }

        if let index = CommandLine.arguments.firstIndex(of: "--set-rpm"),
           CommandLine.arguments.indices.contains(index + 1),
           let rpm = Double(CommandLine.arguments[index + 1]) {
            do {
                let monitor = try HardwareMonitor()
                let fans = monitor.snapshot().fans
                if FanControlHelperClient.shared.isEnabled {
                    try FanControlHelperClient.shared.setAllFans(indices: fans.map(\.index), rpm: rpm)
                } else {
                    try monitor.setAllFans(targetRPM: rpm)
                }
                print("Set all fans to \(formatRPM(rpm))")
                exit(0)
            } catch {
                print("Error: \(error.localizedDescription)")
                exit(2)
            }
        }

        if CommandLine.arguments.contains("--auto") {
            do {
                let monitor = try HardwareMonitor()
                if FanControlHelperClient.shared.isEnabled {
                    try FanControlHelperClient.shared.restoreAutomatic()
                } else {
                    try monitor.restoreAutomaticControl()
                }
                print("Restored automatic fan control")
                exit(0)
            } catch {
                print("Error: \(error.localizedDescription)")
                exit(2)
            }
        }

        if CommandLine.arguments.contains("--helper-status") {
            print(FanControlHelperClient.shared.state.title)
            exit(0)
        }

        if CommandLine.arguments.contains("--install-helper") {
            do {
                let state = try FanControlHelperClient.shared.register(force: CommandLine.arguments.contains("--force-helper"))
                print(state.title)
                if state == .requiresApproval {
                    FanControlHelperClient.shared.openLoginItems()
                }
                exit(state == .enabled ? 0 : 3)
            } catch {
                print("Error: \(error.localizedDescription)")
                exit(2)
            }
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

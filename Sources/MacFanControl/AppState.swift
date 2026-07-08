import Foundation
import Combine

struct FanStrategyRule: Identifiable, Codable, Equatable {
    var id: UUID
    var temperatureCelsius: Double
    var targetRPM: Double

    init(id: UUID = UUID(), temperatureCelsius: Double, targetRPM: Double) {
        self.id = id
        self.temperatureCelsius = temperatureCelsius
        self.targetRPM = targetRPM
    }
}

@MainActor
final class FanControlStore: ObservableObject {
    @Published private(set) var snapshot = HardwareSnapshot.empty
    @Published private(set) var lastAction = "等待刷新"
    @Published private(set) var strategyIsActive = false
    @Published private(set) var hasHardwareAccess = false
    @Published private(set) var helperState = FanControlHelperClient.shared.state
    @Published private(set) var fanDraftRPM: [Int: Double] = [:]

    @Published var strategyEnabled: Bool {
        didSet {
            defaults.set(strategyEnabled, forKey: Defaults.strategyEnabled)
            manualOverrideUntil = nil
            if !strategyEnabled {
                restoreAutomaticControl()
            }
            updateRefreshTimer()
        }
    }

    @Published var temperatureScope: TemperatureScope {
        didSet { defaults.set(temperatureScope.rawValue, forKey: Defaults.temperatureScope) }
    }

    @Published var autoControlBelowCelsius: Double {
        didSet { defaults.set(autoControlBelowCelsius, forKey: Defaults.autoControlBelowCelsius) }
    }

    @Published var strategyRules: [FanStrategyRule] {
        didSet { persistStrategyRules() }
    }

    private let defaults = UserDefaults.standard
    private var monitor: HardwareMonitor?
    private var timer: Timer?
    private var isWindowVisible = false
    private var isSystemAwake = true
    private var isScreenAwake = true
    private var isSessionActive = true
    private var editingFanIndices = Set<Int>()
    private var fanApplyTasks: [Int: Task<Void, Never>] = [:]
    private var manualOverrideUntil: Date?
    private var lastAppliedStrategyRPM: Double?

    init() {
        strategyEnabled = defaults.object(forKey: Defaults.strategyEnabled) as? Bool ?? false
        let rawScope = defaults.string(forKey: Defaults.temperatureScope) ?? TemperatureScope.all.rawValue
        temperatureScope = TemperatureScope(rawValue: rawScope) ?? .all

        let legacyThreshold = defaults.object(forKey: Defaults.thresholdCelsius) as? Double ?? 72
        let legacyTarget = defaults.object(forKey: Defaults.targetRPM) as? Double ?? 3_800
        autoControlBelowCelsius = defaults.object(forKey: Defaults.autoControlBelowCelsius) as? Double ?? max(35, legacyThreshold - 8)
        strategyRules = Self.loadStrategyRules(defaults: defaults, legacyThreshold: legacyThreshold, legacyTarget: legacyTarget)

        do {
            monitor = try HardwareMonitor()
            hasHardwareAccess = true
        } catch {
            hasHardwareAccess = false
            lastAction = error.localizedDescription
            snapshot = HardwareSnapshot(sampledAt: Date(), fans: [], temperatures: [], errorMessage: error.localizedDescription)
        }
    }

    deinit {
        timer?.invalidate()
        fanApplyTasks.values.forEach { $0.cancel() }
    }

    func start() {
        refresh()
        updateRefreshTimer()
    }

    func setWindowVisible(_ visible: Bool) {
        isWindowVisible = visible
        if visible {
            refresh()
        }
        updateRefreshTimer()
    }

    func suspendForSystemSleep() {
        isSystemAwake = false
        stopRefreshTimer()
        cancelPendingFanWrites()
        lastAction = "系统休眠，已暂停"
    }

    func resumeAfterSystemWake() {
        isSystemAwake = true
        lastAction = "系统唤醒，等待刷新"
        updateRefreshTimer()
        scheduleWakeRefresh()
    }

    func setScreenAwake(_ awake: Bool) {
        isScreenAwake = awake
        if awake {
            updateRefreshTimer()
            scheduleWakeRefresh()
        } else {
            stopRefreshTimer()
            cancelPendingFanWrites()
            lastAction = "屏幕休眠，已暂停"
        }
    }

    func setSessionActive(_ active: Bool) {
        isSessionActive = active
        if active {
            updateRefreshTimer()
            scheduleWakeRefresh()
        } else {
            stopRefreshTimer()
            cancelPendingFanWrites()
            lastAction = "会话非活动，已暂停"
        }
    }

    func refresh() {
        guard shouldRunWork else { return }
        guard let monitor else { return }
        helperState = FanControlHelperClient.shared.state
        let next = monitor.snapshot()
        snapshot = next
        syncFanDrafts(with: next.fans)
        hasHardwareAccess = next.errorMessage == nil || !next.fans.isEmpty || !next.temperatures.isEmpty

        if let errorMessage = next.errorMessage {
            lastAction = errorMessage
        } else {
            lastAction = "已刷新 \(timeFormatter.string(from: next.sampledAt))"
        }

        applyStrategyIfNeeded(using: next)
    }

    func applyTargetNow() {
        guard shouldRunWork else { return }
        guard let monitor else { return }
        guard let temperature = selectedTemperature() else {
            lastAction = "没有可用温度传感器"
            return
        }
        guard let rule = matchingRule(for: temperature) else {
            restoreAutomaticControl()
            return
        }

        do {
            try setFans(targetRPM: rule.targetRPM, using: monitor)
            lastAppliedStrategyRPM = rule.targetRPM
            strategyIsActive = true
            lastAction = "已应用 \(formatTemperature(rule.temperatureCelsius)) -> \(formatRPM(rule.targetRPM))"
            refresh()
        } catch {
            lastAction = error.localizedDescription
        }
    }

    func restoreAutomaticControl() {
        guard isSystemAwake else { return }
        guard let monitor else { return }
        do {
            try restoreFans(using: monitor)
            strategyIsActive = false
            lastAppliedStrategyRPM = nil
            lastAction = "已恢复系统自动控制"
            snapshot = monitor.snapshot()
            syncFanDrafts(with: snapshot.fans)
        } catch {
            lastAction = error.localizedDescription
        }
    }

    func selectedTemperature() -> Double? {
        snapshot.maximumTemperature(for: temperatureScope)
    }

    var strategyStatusTitle: String {
        if !strategyEnabled {
            return "未启用"
        }
        if isManualOverrideActive {
            return "策略暂缓"
        }
        return strategyIsActive ? "策略生效" : "自动监测"
    }

    var isManualOverrideActive: Bool {
        if let manualOverrideUntil, manualOverrideUntil > Date() {
            return true
        }
        return false
    }

    func rpmBounds() -> ClosedRange<Double> {
        let minimum = snapshot.fans.compactMap(\.minimumRPM).min() ?? 1_200
        let maximum = snapshot.fans.compactMap(\.maximumRPM).max() ?? 7_000
        return minimum...max(minimum + 100, maximum)
    }

    func rpmBounds(for fan: FanReading) -> ClosedRange<Double> {
        let minimum = fan.minimumRPM ?? 1_200
        let maximum = fan.maximumRPM ?? max(minimum + 100, 7_000)
        return minimum...max(minimum + 100, maximum)
    }

    func sliderRPM(for fan: FanReading) -> Double {
        let bounds = rpmBounds(for: fan)
        let value = fanDraftRPM[fan.index] ?? fan.currentRPM ?? bounds.lowerBound
        return min(bounds.upperBound, max(bounds.lowerBound, value))
    }

    func beginFanEdit(index: Int) {
        editingFanIndices.insert(index)
        fanApplyTasks[index]?.cancel()
    }

    func updateFanDraft(index: Int, rpm: Double) {
        fanDraftRPM[index] = roundedRPM(rpm)
        if shouldRunWork {
            scheduleFanDraftApply(index: index)
        }
    }

    func endFanEdit(index: Int) {
        editingFanIndices.remove(index)
        fanApplyTasks[index]?.cancel()
        fanApplyTasks[index] = nil
        applyFanDraft(index: index)
    }

    func applyFanDraft(index: Int) {
        guard let rpm = fanDraftRPM[index] else { return }
        setFanTarget(index: index, targetRPM: rpm)
    }

    func updateAutoControlBelowCelsius(_ value: Double) {
        autoControlBelowCelsius = roundedTemperature(value)
    }

    func addStrategyRule() {
        let baseTemperature = (strategyRules.map(\.temperatureCelsius).max() ?? autoControlBelowCelsius) + 8
        let baseRPM = (strategyRules.map(\.targetRPM).max() ?? rpmBounds().lowerBound) + 500
        let bounds = rpmBounds()
        strategyRules.append(FanStrategyRule(
            temperatureCelsius: min(105, baseTemperature),
            targetRPM: min(bounds.upperBound, max(bounds.lowerBound, baseRPM))
        ))
        sortStrategyRules()
    }

    func removeStrategyRule(id: UUID) {
        guard strategyRules.count > 1 else { return }
        strategyRules.removeAll { $0.id == id }
    }

    func updateStrategyTemperature(id: UUID, value: Double) {
        guard let index = strategyRules.firstIndex(where: { $0.id == id }) else { return }
        strategyRules[index].temperatureCelsius = min(110, max(30, roundedTemperature(value)))
        sortStrategyRules()
    }

    func updateStrategyRPM(id: UUID, value: Double) {
        guard let index = strategyRules.firstIndex(where: { $0.id == id }) else { return }
        let bounds = rpmBounds()
        strategyRules[index].targetRPM = min(bounds.upperBound, max(bounds.lowerBound, roundedRPM(value)))
    }

    func installHelper() {
        do {
            helperState = try FanControlHelperClient.shared.register()
            switch helperState {
            case .enabled:
                lastAction = "风扇控制程序已启用"
            case .requiresApproval:
                lastAction = "请在系统设置的登录项中批准风扇控制程序"
                FanControlHelperClient.shared.openLoginItems()
            default:
                lastAction = helperState.title
            }
        } catch {
            helperState = FanControlHelperClient.shared.state
            lastAction = error.localizedDescription
        }
    }

    func openHelperSettings() {
        FanControlHelperClient.shared.openLoginItems()
    }

    private func applyStrategyIfNeeded(using snapshot: HardwareSnapshot) {
        guard shouldRunWork, strategyEnabled, let monitor else { return }
        if let until = manualOverrideUntil, until > Date() {
            lastAction = "手动覆盖中，策略暂缓"
            return
        }

        guard let temperature = snapshot.maximumTemperature(for: temperatureScope) else {
            lastAction = "没有可用温度传感器"
            return
        }

        do {
            if temperature < autoControlBelowCelsius {
                if strategyIsActive || lastAppliedStrategyRPM != nil || snapshot.fans.contains(where: \.isManual) {
                    try restoreFans(using: monitor)
                }
                strategyIsActive = false
                lastAppliedStrategyRPM = nil
                lastAction = "低于 \(formatTemperature(autoControlBelowCelsius))，系统自动控制"
                return
            }

            guard let rule = matchingRule(for: temperature) else {
                return
            }

            if lastAppliedStrategyRPM != rule.targetRPM || !strategyIsActive {
                try setFans(targetRPM: rule.targetRPM, using: monitor)
                lastAppliedStrategyRPM = rule.targetRPM
            }
            strategyIsActive = true
            lastAction = "策略生效：\(formatTemperature(temperature)) -> \(formatRPM(rule.targetRPM))"
        } catch {
            lastAction = error.localizedDescription
        }
    }

    private func matchingRule(for temperature: Double) -> FanStrategyRule? {
        let sorted = strategyRules.sorted { $0.temperatureCelsius < $1.temperatureCelsius }
        return sorted.last { temperature >= $0.temperatureCelsius } ?? sorted.first
    }

    private func setFans(targetRPM: Double, using monitor: HardwareMonitor) throws {
        let fans = snapshot.fans.isEmpty ? monitor.snapshot().fans : snapshot.fans
        guard !fans.isEmpty else {
            throw SMCClientError.noFansAvailable
        }

        if FanControlHelperClient.shared.isEnabled {
            try FanControlHelperClient.shared.setAllFans(indices: fans.map(\.index), rpm: targetRPM)
            return
        }

        do {
            try monitor.setAllFans(targetRPM: targetRPM)
        } catch {
            throw FanControlHelperError.requiresApproval(FanControlHelperClient.shared.state)
        }
    }

    private func setFanTarget(index: Int, targetRPM: Double) {
        guard shouldRunWork else { return }
        guard let monitor else { return }
        let roundedTargetRPM = roundedRPM(targetRPM)
        do {
            try setFan(index: index, targetRPM: roundedTargetRPM, using: monitor)
            manualOverrideUntil = Date().addingTimeInterval(600)
            strategyIsActive = false
            lastAppliedStrategyRPM = nil
            lastAction = "Fan \(index) 已设置为 \(formatRPM(roundedTargetRPM))"
        } catch {
            lastAction = error.localizedDescription
        }
    }

    private func setFan(index: Int, targetRPM: Double, using monitor: HardwareMonitor) throws {
        let fans = snapshot.fans.isEmpty ? monitor.snapshot().fans : snapshot.fans
        guard fans.contains(where: { $0.index == index }) else {
            throw SMCClientError.noFansAvailable
        }

        if FanControlHelperClient.shared.isEnabled {
            try FanControlHelperClient.shared.setAllFans(indices: [index], rpm: targetRPM)
            return
        }

        do {
            try monitor.setFan(index: index, targetRPM: targetRPM)
        } catch {
            throw FanControlHelperError.requiresApproval(FanControlHelperClient.shared.state)
        }
    }

    private func restoreFans(using monitor: HardwareMonitor) throws {
        if FanControlHelperClient.shared.isEnabled {
            try FanControlHelperClient.shared.restoreAutomatic()
            return
        }

        do {
            try monitor.restoreAutomaticControl()
        } catch {
            throw FanControlHelperError.requiresApproval(FanControlHelperClient.shared.state)
        }
    }

    private func syncFanDrafts(with fans: [FanReading]) {
        for fan in fans where !editingFanIndices.contains(fan.index) {
            if fan.isManual, let target = fan.targetRPM {
                fanDraftRPM[fan.index] = target
            } else if let current = fan.currentRPM {
                fanDraftRPM[fan.index] = current
            }
        }
    }

    private func scheduleFanDraftApply(index: Int) {
        fanApplyTasks[index]?.cancel()
        fanApplyTasks[index] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            self?.applyFanDraft(index: index)
        }
    }

    private var shouldRunWork: Bool {
        isSystemAwake && isScreenAwake && isSessionActive && (isWindowVisible || strategyEnabled)
    }

    private var refreshInterval: TimeInterval {
        isWindowVisible ? 5 : 20
    }

    private func updateRefreshTimer() {
        stopRefreshTimer()
        guard shouldRunWork else { return }

        let timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        timer.tolerance = max(1, refreshInterval * 0.35)
        self.timer = timer
    }

    private func stopRefreshTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func cancelPendingFanWrites() {
        fanApplyTasks.values.forEach { $0.cancel() }
        fanApplyTasks.removeAll()
        editingFanIndices.removeAll()
    }

    private func scheduleWakeRefresh() {
        guard shouldRunWork else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func sortStrategyRules() {
        strategyRules.sort { $0.temperatureCelsius < $1.temperatureCelsius }
    }

    private func persistStrategyRules() {
        guard let encoded = try? JSONEncoder().encode(strategyRules) else { return }
        defaults.set(encoded, forKey: Defaults.strategyRules)
    }

    private static func loadStrategyRules(defaults: UserDefaults, legacyThreshold: Double, legacyTarget: Double) -> [FanStrategyRule] {
        if let data = defaults.data(forKey: Defaults.strategyRules),
           let decoded = try? JSONDecoder().decode([FanStrategyRule].self, from: data),
           !decoded.isEmpty {
            return decoded.sorted { $0.temperatureCelsius < $1.temperatureCelsius }
        }

        return [
            FanStrategyRule(temperatureCelsius: legacyThreshold, targetRPM: legacyTarget),
            FanStrategyRule(temperatureCelsius: min(95, legacyThreshold + 10), targetRPM: min(6_000, legacyTarget + 1_200))
        ].sorted { $0.temperatureCelsius < $1.temperatureCelsius }
    }
}

private func roundedTemperature(_ value: Double) -> Double {
    value.rounded()
}

private func roundedRPM(_ value: Double) -> Double {
    (value / 50.0).rounded() * 50.0
}

private enum Defaults {
    static let strategyEnabled = "strategyEnabled"
    static let thresholdCelsius = "thresholdCelsius"
    static let targetRPM = "targetRPM"
    static let temperatureScope = "temperatureScope"
    static let autoControlBelowCelsius = "autoControlBelowCelsius"
    static let strategyRules = "strategyRules"
}

let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.timeStyle = .medium
    formatter.dateStyle = .none
    return formatter
}()

func formatTemperature(_ value: Double?) -> String {
    guard let value else { return "-- °C" }
    return "\(Int(value.rounded())) °C"
}

func formatRPM(_ value: Double?) -> String {
    guard let value else { return "-- rpm" }
    return "\(Int(value.rounded())) rpm"
}

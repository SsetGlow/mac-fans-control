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
            strategyRetryAfter = nil
            strategyRetryDelay = 5
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
    private var refreshTask: Task<Void, Never>?
    private var isWindowVisible = false
    private var isSystemAwake = true
    private var isScreenAwake = true
    private var isSessionActive = true
    private var editingFanIndices = Set<Int>()
    private var fanApplyTasks: [Int: Task<Void, Never>] = [:]
    private var hardwareExecutor: HardwareCommandExecutor?
    private var hardwareCommandInFlight = false
    private var pendingHardwareCommand: HardwareCommand?
    private var hardwareMayBeManual = false
    private var isTerminating = false
    private var automaticRestoreRequired = false
    private var strategyRetryAfter: Date?
    private var strategyRetryDelay: TimeInterval = 5
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
            let monitor = try HardwareMonitor()
            self.monitor = monitor
            hardwareExecutor = HardwareCommandExecutor(monitor: monitor)
            hasHardwareAccess = true
        } catch {
            hasHardwareAccess = false
            lastAction = error.localizedDescription
            snapshot = HardwareSnapshot(sampledAt: Date(), fans: [], temperatures: [], errorMessage: error.localizedDescription)
        }
    }

    deinit {
        timer?.invalidate()
        refreshTask?.cancel()
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
        suspendHardwareCommands()
        lastAction = "系统休眠，已暂停"
    }

    func resumeAfterSystemWake() {
        isSystemAwake = true
        lastAction = "系统唤醒，等待刷新"
        updateHardwareExecutorGate()
        updateRefreshTimer()
        scheduleWakeRefresh()
    }

    func setScreenAwake(_ awake: Bool) {
        isScreenAwake = awake
        if awake {
            updateHardwareExecutorGate()
            updateRefreshTimer()
            scheduleWakeRefresh()
        } else {
            stopRefreshTimer()
            suspendHardwareCommands()
            lastAction = "屏幕休眠，已暂停"
        }
    }

    func setSessionActive(_ active: Bool) {
        isSessionActive = active
        if active {
            updateHardwareExecutorGate()
            updateRefreshTimer()
            scheduleWakeRefresh()
        } else {
            stopRefreshTimer()
            suspendHardwareCommands()
            lastAction = "会话非活动，已暂停"
        }
    }

    func refresh() {
        guard shouldRunWork else { return }
        guard let monitor else { return }
        guard refreshTask == nil else { return }

        let currentHelperState = FanControlHelperClient.shared.state
        if helperState != currentHelperState {
            helperState = currentHelperState
        }
        if snapshot.fans.isEmpty, snapshot.temperatures.isEmpty {
            lastAction = "正在读取硬件…"
        }

        refreshTask = Task { [weak self, monitor] in
            let next = await Task.detached(priority: .utility) {
                monitor.snapshot()
            }.value

            guard let self else { return }
            self.refreshTask = nil
            guard !Task.isCancelled, self.shouldRunWork else { return }
            self.finishRefresh(with: next)
        }
    }

    private func finishRefresh(with next: HardwareSnapshot) {
        snapshot = next
        syncFanDrafts(with: next.fans)
        let nextHasHardwareAccess = next.errorMessage == nil || !next.fans.isEmpty || !next.temperatures.isEmpty
        if hasHardwareAccess != nextHasHardwareAccess {
            hasHardwareAccess = nextHasHardwareAccess
        }

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

        scheduleHardwareCommand(
            .setStrategy(indices: snapshot.fans.map(\.index), temperature: temperature, targetRPM: rule.targetRPM),
            using: monitor,
            queueIfBusy: true
        )
    }

    func restoreAutomaticControl() {
        guard isSystemAwake else { return }
        guard let monitor else { return }
        scheduleHardwareCommand(.restore(reason: .userRequested), using: monitor, queueIfBusy: true)
    }

    func prepareForTermination() {
        guard !isTerminating else { return }
        isTerminating = true
        stopRefreshTimer()
        refreshTask?.cancel()
        fanApplyTasks.values.forEach { $0.cancel() }
        fanApplyTasks.removeAll()
        editingFanIndices.removeAll()
        pendingHardwareCommand = nil
        if let errorMessage = hardwareExecutor?.terminateAndRestore() {
            lastAction = errorMessage
        } else {
            strategyIsActive = false
            lastAppliedStrategyRPM = nil
            manualOverrideUntil = nil
            hardwareMayBeManual = false
            automaticRestoreRequired = false
        }
        hardwareCommandInFlight = false
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
        guard shouldRunWork, let monitor else { return }
        if automaticRestoreRequired {
            if let retryAfter = strategyRetryAfter, retryAfter > Date() {
                let seconds = max(1, Int(retryAfter.timeIntervalSinceNow.rounded(.up)))
                lastAction = "恢复系统自动控制失败，约 \(seconds) 秒后重试"
                return
            }
            scheduleHardwareCommand(
                .restore(reason: .failureRecovery),
                using: monitor,
                queueIfBusy: false
            )
            return
        }

        guard strategyEnabled else { return }
        if let until = manualOverrideUntil, until > Date() {
            lastAction = "手动覆盖中，策略暂缓"
            return
        }
        if let retryAfter = strategyRetryAfter, retryAfter > Date() {
            let seconds = max(1, Int(retryAfter.timeIntervalSinceNow.rounded(.up)))
            lastAction = "风扇控制暂不可用，约 \(seconds) 秒后重试"
            return
        }

        guard let temperature = snapshot.maximumTemperature(for: temperatureScope) else {
            lastAction = "没有可用温度传感器"
            return
        }

        if temperature < autoControlBelowCelsius {
            if strategyIsActive || lastAppliedStrategyRPM != nil || snapshot.fans.contains(where: \.isManual) {
                scheduleHardwareCommand(
                    .restore(reason: .belowThreshold(autoControlBelowCelsius)),
                    using: monitor,
                    queueIfBusy: false
                )
            } else {
                strategyIsActive = false
                lastAppliedStrategyRPM = nil
                lastAction = "低于 \(formatTemperature(autoControlBelowCelsius))，系统自动控制"
            }
            return
        }

        guard let rule = matchingRule(for: temperature) else {
            return
        }

        if lastAppliedStrategyRPM != rule.targetRPM || !strategyIsActive {
            scheduleHardwareCommand(
                .setStrategy(indices: snapshot.fans.map(\.index), temperature: temperature, targetRPM: rule.targetRPM),
                using: monitor,
                queueIfBusy: false
            )
        } else {
            strategyIsActive = true
            lastAction = "策略生效：\(formatTemperature(temperature)) -> \(formatRPM(rule.targetRPM))"
        }
    }

    private func scheduleHardwareCommand(
        _ command: HardwareCommand,
        using _: HardwareMonitor,
        queueIfBusy: Bool
    ) {
        guard hardwareExecutionAllowed, let hardwareExecutor else { return }
        guard !hardwareCommandInFlight else {
            if queueIfBusy {
                pendingHardwareCommand = command
            }
            return
        }
        if case .setStrategy(let indices, _, _) = command, indices.isEmpty {
            lastAction = SMCClientError.noFansAvailable.localizedDescription
            return
        }

        switch command {
        case .setStrategy:
            lastAction = "正在后台应用风扇策略…"
        case .setManual(let index, let targetRPM):
            lastAction = "正在后台设置 Fan \(index) 为 \(formatRPM(targetRPM))…"
        case .restore:
            lastAction = "正在后台恢复系统自动控制…"
        }

        hardwareCommandInFlight = true
        let accepted = hardwareExecutor.submit(command) { [weak self] result in
            Task { @MainActor in
                self?.finishHardwareCommand(command, result: result)
            }
        }
        if accepted, command.isSetCommand {
            hardwareMayBeManual = true
        } else if !accepted {
            hardwareCommandInFlight = false
        }
    }

    private func finishHardwareCommand(_ command: HardwareCommand, result: HardwareCommandResult) {
        hardwareCommandInFlight = false
        guard !isTerminating else {
            pendingHardwareCommand = nil
            return
        }

        guard hardwareExecutionAllowed else {
            pendingHardwareCommand = nil
            strategyIsActive = false
            lastAppliedStrategyRPM = nil
            return
        }

        switch result {
        case .success:
            applySuccessfulHardwareCommand(command)
        case .failed(let commandError, let recoveryError):
            pendingHardwareCommand = nil
            strategyIsActive = false
            lastAppliedStrategyRPM = nil
            let recoveredFromSetFailure = command.isSetCommand && recoveryError == nil
            if command.isSetCommand, let recoveryError {
                recordAutomaticRestoreFailure("\(commandError)；恢复系统自动控制失败：\(recoveryError)")
            } else if command.isSetCommand {
                hardwareMayBeManual = false
                automaticRestoreRequired = false
                strategyRetryAfter = Date().addingTimeInterval(30)
                strategyRetryDelay = 5
                lastAction = "\(commandError)；已安全恢复系统自动控制，30 秒后再尝试策略"
            } else {
                recordAutomaticRestoreFailure(commandError)
            }
            updateRefreshTimer()
            if recoveredFromSetFailure {
                refresh()
            }
            return
        case .discarded:
            pendingHardwareCommand = nil
            strategyIsActive = false
            lastAppliedStrategyRPM = nil
            return
        }

        if let pending = pendingHardwareCommand {
            pendingHardwareCommand = nil
            if let monitor {
                scheduleHardwareCommand(pending, using: monitor, queueIfBusy: true)
            }
        } else {
            refresh()
        }
    }

    private func applySuccessfulHardwareCommand(_ command: HardwareCommand) {
        switch command {
        case .setStrategy(_, let temperature, let targetRPM):
            automaticRestoreRequired = false
            strategyRetryAfter = nil
            strategyRetryDelay = 5
            lastAppliedStrategyRPM = targetRPM
            strategyIsActive = true
            lastAction = "策略生效：\(formatTemperature(temperature)) -> \(formatRPM(targetRPM))"
        case .setManual(let index, let targetRPM):
            automaticRestoreRequired = false
            strategyRetryAfter = nil
            strategyRetryDelay = 5
            manualOverrideUntil = Date().addingTimeInterval(600)
            strategyIsActive = false
            lastAppliedStrategyRPM = nil
            lastAction = "Fan \(index) 已设置为 \(formatRPM(targetRPM))"
        case .restore(let reason):
            strategyIsActive = false
            lastAppliedStrategyRPM = nil
            manualOverrideUntil = nil
            hardwareMayBeManual = false
            automaticRestoreRequired = false
            strategyRetryDelay = 5
            switch reason {
            case .belowThreshold(let threshold):
                strategyRetryAfter = nil
                lastAction = "低于 \(formatTemperature(threshold))，系统自动控制"
            case .userRequested:
                strategyRetryAfter = nil
                lastAction = "已恢复系统自动控制"
            case .failureRecovery:
                strategyRetryAfter = Date().addingTimeInterval(30)
                lastAction = "已安全恢复系统自动控制，30 秒后再尝试策略"
            }
            updateRefreshTimer()
        }
    }

    private func recordAutomaticRestoreFailure(_ errorMessage: String) {
        let retryDelay = strategyRetryDelay
        hardwareMayBeManual = true
        automaticRestoreRequired = true
        strategyRetryAfter = Date().addingTimeInterval(retryDelay)
        strategyRetryDelay = min(retryDelay * 2, 30)
        strategyIsActive = false
        lastAppliedStrategyRPM = nil
        lastAction = "\(errorMessage)；\(Int(retryDelay)) 秒后重试恢复系统自动控制"
    }

    private func matchingRule(for temperature: Double) -> FanStrategyRule? {
        let sorted = strategyRules.sorted { $0.temperatureCelsius < $1.temperatureCelsius }
        return sorted.last { temperature >= $0.temperatureCelsius } ?? sorted.first
    }

    private func setFanTarget(index: Int, targetRPM: Double) {
        guard shouldRunWork else { return }
        guard let monitor else { return }
        let roundedTargetRPM = roundedRPM(targetRPM)
        scheduleHardwareCommand(
            .setManual(index: index, targetRPM: roundedTargetRPM),
            using: monitor,
            queueIfBusy: true
        )
    }

    private func syncFanDrafts(with fans: [FanReading]) {
        var nextDrafts = fanDraftRPM
        for fan in fans where !editingFanIndices.contains(fan.index) {
            if fan.isManual, let target = fan.targetRPM {
                nextDrafts[fan.index] = target
            } else if let current = fan.currentRPM {
                nextDrafts[fan.index] = current
            }
        }
        if nextDrafts != fanDraftRPM {
            fanDraftRPM = nextDrafts
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
        isSystemAwake && isScreenAwake && isSessionActive
            && (isWindowVisible || strategyEnabled || automaticRestoreRequired)
    }

    private var hardwareExecutionAllowed: Bool {
        !isTerminating && isSystemAwake && isScreenAwake && isSessionActive
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

    private func suspendHardwareCommands() {
        fanApplyTasks.values.forEach { $0.cancel() }
        fanApplyTasks.removeAll()
        editingFanIndices.removeAll()
        pendingHardwareCommand = nil

        let restoreRequired = hardwareCommandInFlight
            || hardwareMayBeManual
            || manualOverrideUntil != nil
            || automaticRestoreRequired
            || strategyIsActive
            || lastAppliedStrategyRPM != nil
            || snapshot.fans.contains(where: \.isManual)
        if restoreRequired {
            automaticRestoreRequired = true
        }

        hardwareExecutor?.suspend(restoreAutomatic: restoreRequired) { [weak self] result in
            Task { @MainActor in
                self?.finishSuspensionRestore(result)
            }
        }
    }

    private func updateHardwareExecutorGate() {
        guard !isTerminating else { return }
        if isSystemAwake && isScreenAwake && isSessionActive {
            hardwareExecutor?.resume()
        } else {
            suspendHardwareCommands()
        }
    }

    private func finishSuspensionRestore(_ result: SafetyRestoreResult) {
        guard !isTerminating else { return }
        strategyIsActive = false
        lastAppliedStrategyRPM = nil
        manualOverrideUntil = nil

        switch result {
        case .success:
            hardwareMayBeManual = false
            automaticRestoreRequired = false
            strategyRetryAfter = nil
            strategyRetryDelay = 5
            if hardwareExecutionAllowed {
                updateRefreshTimer()
                refresh()
            }
        case .failed(let errorMessage):
            let retryDelay = strategyRetryDelay
            hardwareMayBeManual = true
            automaticRestoreRequired = true
            strategyRetryAfter = Date().addingTimeInterval(retryDelay)
            strategyRetryDelay = min(retryDelay * 2, 30)
            if hardwareExecutionAllowed {
                lastAction = "\(errorMessage)；\(Int(retryDelay)) 秒后重试恢复系统自动控制"
                updateRefreshTimer()
            }
        }
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

private enum HardwareCommand: Sendable {
    case setStrategy(indices: [Int], temperature: Double, targetRPM: Double)
    case setManual(index: Int, targetRPM: Double)
    case restore(reason: RestoreReason)

    var isSetCommand: Bool {
        switch self {
        case .setStrategy, .setManual:
            return true
        case .restore:
            return false
        }
    }
}

private enum RestoreReason: Sendable {
    case belowThreshold(Double)
    case userRequested
    case failureRecovery
}

private enum HardwareCommandResult: Sendable {
    case success
    case failed(commandError: String, recoveryError: String?)
    case discarded
}

private enum SafetyRestoreResult: Sendable {
    case success
    case failed(String)
}

private final class HardwareCommandExecutor: @unchecked Sendable {
    private enum GateState {
        case running
        case suspended
        case terminating
        case terminated
    }

    private let monitor: HardwareMonitor
    private let queue = DispatchQueue(label: "local.mac-fan-control.hardware-writes", qos: .utility)
    private let stateLock = NSLock()
    private var gateState: GateState = .running
    private var gateGeneration: UInt64 = 0
    private var suspensionBarrierPending = false
    private var suspensionRestoreRequired = false
    private var suspensionCallbacks: [@Sendable (SafetyRestoreResult) -> Void] = []

    init(monitor: HardwareMonitor) {
        self.monitor = monitor
    }

    @discardableResult
    func submit(
        _ command: HardwareCommand,
        completion: @escaping @Sendable (HardwareCommandResult) -> Void
    ) -> Bool {
        stateLock.lock()
        guard gateState == .running else {
            stateLock.unlock()
            return false
        }
        let submittedGeneration = gateGeneration

        queue.async { [weak self] in
            guard let self else { return }
            guard self.canStartNormalCommand(generation: submittedGeneration) else {
                self.deliver(.discarded, to: completion)
                return
            }
            self.deliver(self.execute(command), to: completion)
        }
        stateLock.unlock()
        return true
    }

    func suspend(
        restoreAutomatic: Bool,
        completion: @escaping @Sendable (SafetyRestoreResult) -> Void
    ) {
        stateLock.lock()
        guard gateState != .terminating, gateState != .terminated else {
            stateLock.unlock()
            deliver(.success, to: completion)
            return
        }

        gateState = .suspended
        gateGeneration &+= 1
        suspensionRestoreRequired = suspensionRestoreRequired || restoreAutomatic
        suspensionCallbacks.append(completion)
        if !suspensionBarrierPending {
            suspensionBarrierPending = true
            queue.async { [weak self] in
                self?.runSuspensionBarrier()
            }
        }
        stateLock.unlock()
    }

    func resume() {
        stateLock.lock()
        if gateState == .suspended {
            gateState = .running
        }
        stateLock.unlock()
    }

    func terminateAndRestore() -> String? {
        stateLock.lock()
        guard gateState != .terminated else {
            stateLock.unlock()
            return nil
        }
        gateState = .terminating
        gateGeneration &+= 1
        stateLock.unlock()

        var finalError: String?
        queue.sync {
            do {
                try restoreAutomaticControl()
            } catch {
                finalError = error.localizedDescription
            }

            stateLock.lock()
            gateState = .terminated
            suspensionRestoreRequired = false
            stateLock.unlock()
        }
        return finalError
    }

    private func canStartNormalCommand(generation: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return gateState == .running && gateGeneration == generation
    }

    private func execute(_ command: HardwareCommand) -> HardwareCommandResult {
        do {
            try perform(command)
            return .success
        } catch {
            let commandError = error.localizedDescription
            guard command.isSetCommand else {
                return .failed(commandError: commandError, recoveryError: nil)
            }

            do {
                // A set can partially succeed (for example, only one fan changed).
                // Restore in this same serial section before any later command starts.
                try restoreAutomaticControl()
                return .failed(commandError: commandError, recoveryError: nil)
            } catch {
                return .failed(commandError: commandError, recoveryError: error.localizedDescription)
            }
        }
    }

    private func perform(_ command: HardwareCommand) throws {
        switch command {
        case .setStrategy(let indices, _, let targetRPM):
            if FanControlHelperClient.shared.isEnabled {
                try FanControlHelperClient.shared.setAllFans(indices: indices, rpm: targetRPM)
            } else {
                try monitor.setAllFans(targetRPM: targetRPM)
            }
        case .setManual(let index, let targetRPM):
            if FanControlHelperClient.shared.isEnabled {
                try FanControlHelperClient.shared.setAllFans(indices: [index], rpm: targetRPM)
            } else {
                try monitor.setFan(index: index, targetRPM: targetRPM)
            }
        case .restore:
            try restoreAutomaticControl()
        }
    }

    private func restoreAutomaticControl() throws {
        if FanControlHelperClient.shared.isEnabled {
            try FanControlHelperClient.shared.restoreAutomatic()
        } else {
            try monitor.restoreAutomaticControl()
        }
    }

    private func runSuspensionBarrier() {
        var finalResult = SafetyRestoreResult.success

        while true {
            stateLock.lock()
            let shouldRestore = suspensionRestoreRequired
            suspensionRestoreRequired = false
            stateLock.unlock()

            if shouldRestore {
                do {
                    try restoreAutomaticControl()
                    finalResult = .success
                } catch {
                    finalResult = .failed(error.localizedDescription)
                }
            }

            stateLock.lock()
            if suspensionRestoreRequired {
                stateLock.unlock()
                continue
            }
            let callbacks = suspensionCallbacks
            suspensionCallbacks.removeAll()
            suspensionBarrierPending = false
            stateLock.unlock()

            callbacks.forEach { deliver(finalResult, to: $0) }
            return
        }
    }

    private func deliver<T: Sendable>(_ result: T, to completion: @escaping @Sendable (T) -> Void) {
        DispatchQueue.main.async {
            completion(result)
        }
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

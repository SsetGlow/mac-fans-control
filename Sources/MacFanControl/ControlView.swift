import SwiftUI

struct ControlView: View {
    @ObservedObject var store: FanControlStore

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(spacing: 18) {
                    overview
                    strategyPanel
                    fanPanel
                    temperaturePanel
                }
                .padding(20)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 760, minHeight: 640)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "fanblades")
                .font(.system(size: 26, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.teal)

            VStack(alignment: .leading, spacing: 3) {
                Text("Mac Fan Control")
                    .font(.system(size: 22, weight: .semibold))
                Text(store.lastAction)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                store.refresh()
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)

            Button {
                store.restoreAutomaticControl()
            } label: {
                Label("自动", systemImage: "dial.low")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var overview: some View {
        HStack(spacing: 12) {
            MetricTile(
                title: "最高温度",
                value: formatTemperature(store.snapshot.maximumTemperature),
                systemImage: "thermometer.medium",
                tint: .red
            )

            MetricTile(
                title: "当前风扇",
                value: store.snapshot.fans.first.map { formatRPM($0.currentRPM) } ?? "-- rpm",
                systemImage: "fanblades",
                tint: .teal
            )

            MetricTile(
                title: "策略状态",
                value: store.strategyStatusTitle,
                systemImage: store.strategyEnabled ? "bolt.circle" : "pause.circle",
                tint: store.strategyEnabled ? .orange : .secondary
            )
        }
    }

    private var strategyPanel: some View {
        Panel(title: "风扇策略", systemImage: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 16) {
                Toggle(isOn: $store.strategyEnabled) {
                    Label("启用自动策略", systemImage: "power")
                }
                .toggleStyle(.switch)

                Picker("温度来源", selection: $store.temperatureScope) {
                    ForEach(TemperatureScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Label("低于", systemImage: "dial.low")
                        Text(formatTemperature(store.autoControlBelowCelsius))
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text("交还系统自动控制")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }

                    Slider(
                        value: Binding(
                            get: { store.autoControlBelowCelsius },
                            set: { store.updateAutoControlBelowCelsius($0) }
                        ),
                        in: 30...105
                    )
                }
                .padding(12)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))

                VStack(spacing: 8) {
                    HStack {
                        Label("温度", systemImage: "thermometer.sun")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Label("转速", systemImage: "speedometer")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Spacer()
                            .frame(width: 32)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    ForEach(store.strategyRules) { rule in
                        StrategyRuleRow(rule: rule, store: store)
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        store.addStrategyRule()
                    } label: {
                        Label("添加策略", systemImage: "plus.circle")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        store.applyTargetNow()
                    } label: {
                        Label("立即应用策略", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        store.restoreAutomaticControl()
                    } label: {
                        Label("恢复系统自动控制", systemImage: "arrow.uturn.backward.circle")
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    if let selected = store.selectedTemperature() {
                        Text("当前 \(store.temperatureScope.title)：\(formatTemperature(selected))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    private var fanPanel: some View {
        Panel(title: "风扇", systemImage: "fanblades") {
            if store.snapshot.fans.isEmpty {
                EmptyState(text: "没有读取到风扇")
            } else {
                VStack(spacing: 8) {
                    ForEach(store.snapshot.fans) { fan in
                        FanControlRow(fan: fan, store: store)
                    }
                }
            }
        }
    }

    private var temperaturePanel: some View {
        Panel(title: "温度", systemImage: "thermometer") {
            if store.snapshot.temperatures.isEmpty {
                EmptyState(text: store.snapshot.errorMessage ?? "没有读取到温度传感器")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 10)], spacing: 10) {
                    ForEach(store.snapshot.temperatures) { sensor in
                        TemperatureCard(sensor: sensor)
                    }
                }
            }
        }
    }
}

private struct FanControlRow: View {
    let fan: FanReading
    @ObservedObject var store: FanControlStore

    var body: some View {
        let bounds = store.rpmBounds(for: fan)
        let modeTitle = fanModeTitle

        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Fan \(fan.index)")
                    .fontWeight(.semibold)
                Text(modeTitle)
                    .font(.caption)
                    .fontWeight(.medium)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(fanModeTint.opacity(0.16), in: Capsule())
                    .foregroundStyle(fanModeTint)
            }
            .frame(width: 78, alignment: .leading)

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(formatRPM(fan.currentRPM))
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Spacer()
                    Text(fan.isManual ? "目标 \(formatRPM(store.sliderRPM(for: fan)))" : "系统 \(formatRPM(store.sliderRPM(for: fan)))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Slider(
                    value: Binding(
                        get: { store.sliderRPM(for: fan) },
                        set: { store.updateFanDraft(index: fan.index, rpm: $0) }
                    ),
                    in: bounds,
                    onEditingChanged: { isEditing in
                        if isEditing {
                            store.beginFanEdit(index: fan.index)
                        } else {
                            store.endFanEdit(index: fan.index)
                        }
                    }
                )

                HStack {
                    Text("Min \(formatRPM(fan.minimumRPM))")
                    Spacer()
                    Text("Max \(formatRPM(fan.maximumRPM))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var fanModeTitle: String {
        if fan.isManual, store.strategyEnabled, store.strategyIsActive, !store.isManualOverrideActive {
            return "策略"
        }
        return fan.isManual ? "手动" : "系统"
    }

    private var fanModeTint: Color {
        switch fanModeTitle {
        case "策略":
            return .orange
        case "手动":
            return .red
        default:
            return .green
        }
    }
}

private struct StrategyRuleRow: View {
    let rule: FanStrategyRule
    @ObservedObject var store: FanControlStore

    var body: some View {
        HStack(spacing: 12) {
            StrategySliderColumn(
                valueText: formatTemperature(rule.temperatureCelsius),
                value: Binding(
                    get: { rule.temperatureCelsius },
                    set: { store.updateStrategyTemperature(id: rule.id, value: $0) }
                ),
                range: 30...110
            )

            StrategySliderColumn(
                valueText: formatRPM(rule.targetRPM),
                value: Binding(
                    get: { rule.targetRPM },
                    set: { store.updateStrategyRPM(id: rule.id, value: $0) }
                ),
                range: store.rpmBounds()
            )

            Button {
                store.removeStrategyRule(id: rule.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(store.strategyRules.count > 1 ? .red : .secondary)
            .disabled(store.strategyRules.count <= 1)
            .help("删除策略")
            .frame(width: 32)
        }
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct StrategySliderColumn: View {
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(valueText)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Slider(value: $value, in: range)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TemperatureCard: View {
    let sensor: TemperatureReading

    var body: some View {
        let tint = temperatureTint(for: sensor.group)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
                Text(sensor.label)
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer()
                Text(sensor.group.title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(tint.opacity(0.14), in: Capsule())
                    .foregroundStyle(tint)
            }

            Text(formatTemperature(sensor.celsius))
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(tint.opacity(0.24), lineWidth: 1)
        }
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 82)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

private func temperatureTint(for group: TemperatureScope) -> Color {
    switch group {
    case .cpu:
        return .orange
    case .gpu:
        return .blue
    case .all:
        return .mint
    }
}

private struct Panel<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct EmptyState: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
            Text(text)
                .lineLimit(2)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 56)
    }
}

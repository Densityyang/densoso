import DensosoDomain
import SwiftUI

struct DailyHealthBriefCard: View {
    let brief: DailyHealthBrief?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("今日摘要", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                OrbitStatusBadge(text: "设备端计算", tone: .blue)
            }

            if let brief {
                Text(brief.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(brief.domains) { domain in
                        domainTile(domain)
                    }
                }

                if let state = brief.healthState {
                    HStack(spacing: 8) {
                        derivedStateTile(
                            title: "恢复",
                            value: recoveryName(state.recovery.status),
                            tint: recoveryColor(state.recovery.status),
                            symbol: "heart.text.square"
                        )
                        derivedStateTile(
                            title: "训练负荷",
                            value: trainingLoadName(state.trainingLoad.band),
                            tint: state.trainingLoad.band == .sharplyIncreased || state.trainingLoad.band == .increased
                                ? OrbitPalette.gold
                                : OrbitPalette.blue,
                            symbol: "figure.run"
                        )
                    }
                    if let guidance = state.tomorrowGuidance,
                       guidance.expectedState != .unknown {
                        Text(guidance.conditionalNote)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if let sleep = brief.sleep {
                    HStack(spacing: 10) {
                        Image(systemName: "bed.double.fill")
                            .foregroundStyle(OrbitPalette.blue)
                        Text(sleep.mainSleepMinutes.map { "主睡眠 \(Int($0.rounded())) 分钟" } ?? "主睡眠数据不足")
                        if sleep.napMinutes > 0 {
                            Text("· 小睡 \(Int(sleep.napMinutes.rounded())) 分钟")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.footnote)
                    .accessibilityElement(children: .combine)
                }

                if !brief.recommendations.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("可以留意")
                            .font(.subheadline.weight(.semibold))
                        ForEach(brief.recommendations) { item in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title).font(.subheadline)
                                Text(item.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("依据：\(item.evidenceKey)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(OrbitPalette.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }

                Text("健康管理提示，不用于疾病判断；缺失数据不会视为零。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                ContentUnavailableView(
                    "摘要等待数据",
                    systemImage: "heart.text.square",
                    description: Text("连接 HealthKit 或记录饮食后，这里会显示本地计算的摘要。")
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .orbitCard(emphasized: true)
        .accessibilityElement(children: .contain)
    }

    private func domainTile(_ result: HealthDomainResult) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color(for: result.status))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(domainName(result.domain))
                    .font(.caption.weight(.semibold))
                Text(statusName(result.status))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(domainName(result.domain))：\(statusName(result.status))")
    }

    private func derivedStateTile(title: String, value: String, tint: Color, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.weight(.semibold))
                Text(value).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    private func domainName(_ domain: HealthDomain) -> String {
        switch domain {
        case .nutrition: "营养"
        case .sleep: "睡眠"
        case .activity: "活动"
        case .body: "身体指标"
        }
    }

    private func statusName(_ status: HealthDomainStatus) -> String {
        switch status {
        case .noData: "暂无数据"
        case .unknown: "数据覆盖未知"
        case .partial: "部分数据"
        case .learning: "学习中"
        case .withinTypicalRange: "处于个人范围"
        case .changed: "与近期不同"
        case .attention: "值得留意"
        }
    }

    private func recoveryName(_ status: RecoveryStatus) -> String {
        switch status {
        case .insufficientEvidence: "数据不足，不作判断"
        case .withinTypicalRange: "处于个人范围"
        case .attention: "建议降低强度"
        }
    }

    private func recoveryColor(_ status: RecoveryStatus) -> Color {
        switch status {
        case .insufficientEvidence: .secondary
        case .withinTypicalRange: OrbitPalette.green
        case .attention: OrbitPalette.coral
        }
    }

    private func trainingLoadName(_ band: TrainingLoadBand) -> String {
        switch band {
        case .unavailable: "暂无数据"
        case .learning: "学习中"
        case .belowTypical: "低于近期范围"
        case .gradualReturn: "逐步恢复"
        case .nearTypical: "接近近期范围"
        case .increased: "有所上升"
        case .sharplyIncreased: "明显上升"
        }
    }

    private func color(for status: HealthDomainStatus) -> Color {
        switch status {
        case .noData: Color.secondary
        case .unknown: Color.secondary
        case .partial: OrbitPalette.blue
        case .learning: OrbitPalette.blue
        case .withinTypicalRange: OrbitPalette.green
        case .changed: OrbitPalette.gold
        case .attention: OrbitPalette.coral
        }
    }
}

struct WeeklyHealthBriefCard: View {
    let brief: WeeklyHealthBrief?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("上周回顾", systemImage: "calendar")
                .font(.headline)
            if let brief {
                Text(brief.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    metric("有数据", value: "\(brief.daysWithData)/7 天")
                    metric("主睡眠", value: minutes(brief.averageSleepMinutes))
                }
                HStack(spacing: 8) {
                    metric("日均摄入", value: energy(brief.averageEnergyIntakeKcal))
                    metric("体重中位数", value: weight(brief.medianWeightKilograms))
                }
                loadSummary(brief.trainingLoad)
                Text("按上一自然周统计；缺失日不补零。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text("完整一周数据尚未形成。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .orbitCard()
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func loadSummary(_ load: TrainingLoadSummary) -> some View {
        if load.dataCoverage == .complete, let ratio = load.ratio {
            Label(
                "训练负荷比 \(ratio.formatted(.number.precision(.fractionLength(2)))) · \(bandName(load.band))",
                systemImage: "figure.run"
            )
            .font(.footnote)
        } else {
            let detail: String
            switch load.dataCoverage {
            case .unknown:
                detail = "训练记录覆盖未知，暂不评估负荷。"
            case .partial:
                detail = "训练记录不完整，暂不评估负荷。"
            case .complete:
                detail = load.unavailableEffortCount > 0
                    ? "有 \(load.unavailableEffortCount) 次运动缺少强度数据，暂不比较"
                    : "训练负荷基线：\(readinessName(load.readiness))"
            }
            Label(detail, systemImage: "figure.run")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func readinessName(_ readiness: BaselineReadiness) -> String {
        switch readiness {
        case .noData: "数据不足"
        case .learning: "学习中"
        case .temporary: "临时基线"
        case .mature: "成熟基线"
        }
    }

    private func bandName(_ band: TrainingLoadBand) -> String {
        switch band {
        case .unavailable: "暂无结论"
        case .learning: "学习中"
        case .belowTypical: "低于近期习惯"
        case .gradualReturn: "逐步恢复"
        case .nearTypical: "接近近期习惯"
        case .increased: "有所增加"
        case .sharplyIncreased: "明显增加"
        }
    }

    private func minutes(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded())) 分钟" } ?? "暂无"
    }

    private func energy(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded())) kcal" } ?? "暂无"
    }

    private func weight(_ value: Double?) -> String {
        value.map { "\($0.formatted(.number.precision(.fractionLength(1)))) kg" } ?? "暂无"
    }
}

struct HealthVitalTrendsCard: View {
    let trends: [HealthVitalTrend]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("身体指标").font(.headline)
            if trends.isEmpty || trends.allSatisfy({ $0.status == .noData }) {
                Text("当前没有足够的生命体征或体重数据。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(trends) { trend in
                    HStack {
                        Text(name(trend.metric))
                        Spacer()
                        Text(value(trend))
                            .monospacedDigit()
                        Text(status(trend.status))
                            .foregroundStyle(trend.status == .attention ? OrbitPalette.coral : Color.secondary)
                    }
                    .font(.footnote)
                    .accessibilityElement(children: .combine)
                }
            }
            Text("只展示个人数据变化，不生成统一健康分或疾病判断。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .orbitCard()
    }

    private func name(_ metric: HealthVitalMetric) -> String {
        switch metric {
        case .restingHeartRate: "静息心率"
        case .heartRateVariability: "HRV"
        case .respiratoryRate: "呼吸频率"
        case .wristTemperature: "睡眠腕温"
        case .bodyWeight: "体重"
        }
    }

    private func value(_ trend: HealthVitalTrend) -> String {
        guard let value = trend.latestMedian else { return "暂无" }
        let digits = trend.metric == .bodyWeight || trend.metric == .wristTemperature ? 1 : 0
        let suffix = trend.metric == .bodyWeight ? " kg" : (trend.metric == .wristTemperature ? " °C" : "")
        return value.formatted(.number.precision(.fractionLength(digits))) + suffix
    }

    private func status(_ value: HealthDomainStatus) -> String {
        switch value {
        case .noData: "无数据"
        case .unknown: "数据覆盖未知"
        case .partial: "部分数据"
        case .learning: "学习中"
        case .withinTypicalRange: "常见范围"
        case .changed: "变化"
        case .attention: "留意"
        }
    }
}

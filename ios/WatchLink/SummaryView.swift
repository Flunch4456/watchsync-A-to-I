import SwiftUI
import Charts

struct HeartZone: Identifiable {
    let id: Int
    let name: String
    let range: String
    let seconds: Double
    var minutes: Double { seconds / 60 }
}

/// Calculs du bilan du jour : zones cardiaques, minutes actives, calories (estimations).
enum DayStats {
    static let zoneNames = ["Repos", "Échauffement", "Endurance", "Soutenu", "Intense"]

    /// Zone 0 à 4 selon le pourcentage du rythme maximal (220 − âge).
    static func zone(bpm: Int, maxHR: Int) -> Int {
        let pct = Double(bpm) / Double(Swift.max(maxHR, 1))
        switch pct {
        case ..<0.5: return 0
        case ..<0.6: return 1
        case ..<0.7: return 2
        case ..<0.85: return 3
        default: return 4
        }
    }

    /// Chaque mesure compte pour l'intervalle de mesure réglé (au moins 10 s, la cadence d'enregistrement).
    static func zones(samples: [Sample], maxHR: Int, intervalSeconds: Int) -> [HeartZone] {
        let weight = Double(Swift.max(10, intervalSeconds))
        var totals = [Double](repeating: 0, count: 5)
        for s in samples { totals[zone(bpm: s.b, maxHR: maxHR)] += weight }
        let limits = ["< 50 %", "50–60 %", "60–70 %", "70–85 %", "> 85 %"]
        return (0..<5).map { HeartZone(id: $0, name: zoneNames[$0], range: limits[$0], seconds: totals[$0]) }
    }

    static func todaySamples(_ sessions: [Session]) -> [Sample] {
        let start = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
        return sessions.flatMap { $0.samples }.filter { $0.t >= start }
    }

    /// Calories actives d'une marche : environ 0,55 kcal par kilo et par kilomètre.
    static func calories(km: Double, weightKg: Int) -> Int {
        Int((km * Double(weightKg) * 0.55).rounded())
    }
}

/// Bilan du jour : objectif de pas, calories, minutes actives, rythme au repos, sommeil, zones cardiaques.
struct SummaryView: View {
    @ObservedObject var manager: HeartRateManager
    @ObservedObject var history: HistoryStore
    @AppStorage(SettingsKey.heightCm) private var heightCm = 175
    @AppStorage(SettingsKey.ageYears) private var age = 25
    @AppStorage(SettingsKey.weightKg) private var weightKg = 70
    @AppStorage(SettingsKey.stepGoal) private var stepGoal = 8000
    @AppStorage(SettingsKey.hrInterval) private var hrInterval = 1

    private var steps: Int { manager.steps ?? history.todaySteps }
    private var km: Double { Double(steps) * Double(heightCm) * 0.415 / 100 / 1000 }
    private var maxHR: Int { 220 - age }

    var body: some View {
        let samples = DayStats.todaySamples(history.sessions)
        let zones = DayStats.zones(samples: samples, maxHR: maxHR, intervalSeconds: hrInterval)
        let activeMinutes = Int(zones.filter { $0.id >= 2 }.map { $0.minutes }.reduce(0, +))
        let allSamples = history.sessions.flatMap { $0.samples }
        let resting = HealthEstimator.restingHeartRate(from: allSamples)
        let night = HealthEstimator.nights(from: allSamples).last {
            Calendar.current.isDateInToday($0.day)
        }

        VStack(alignment: .leading, spacing: 16) {
            Text("Bilan du jour").font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Swift.min(1, Double(steps) / Double(Swift.max(stepGoal, 1))))
                    .tint(.red)
                Text("\(steps) / \(stepGoal) pas")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                tile("\(DayStats.calories(km: km, weightKg: weightKg))", "kcal actives", "flame.fill")
                tile("\(activeMinutes)", "min actives", "timer")
                tile(resting.map { "\($0)" } ?? "--", "bpm au repos", "heart.fill")
                tile(night.map { formatDuration($0.duration) } ?? "--", "sommeil (estimé)", "bed.double.fill")
            }

            Text("Zones cardiaques aujourd'hui")
                .font(.subheadline.bold())
            if samples.isEmpty {
                Text("Pas encore de mesures aujourd'hui.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Chart(zones) { z in
                    BarMark(x: .value("Minutes", z.minutes),
                            y: .value("Zone", z.name))
                        .foregroundStyle(by: .value("Zone", z.name))
                        .annotation(position: .trailing) {
                            Text(formatDuration(z.seconds))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                }
                .chartLegend(.hidden)
                .chartYScale(domain: Array(DayStats.zoneNames.reversed()))
                .frame(height: 190)
            }
            Text("Zones d'après ton rythme maximal estimé de \(maxHR) bpm (220 − âge). Minutes actives = temps à 60 % du maximum ou plus. Calories estimées d'après les pas, ta taille et ton poids : ce sont des ordres de grandeur.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func tile(_ value: String, _ label: String, _ icon: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon).foregroundStyle(.red)
            Text(value)
                .font(.title3.bold())
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}

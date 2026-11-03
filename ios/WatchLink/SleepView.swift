import SwiftUI
import Charts

/// Une nuit estimée à partir des mesures cardiaques (pas une mesure médicale).
struct SleepNight: Identifiable {
    let day: Date          // le matin du réveil
    let start: Date
    let end: Date
    var id: Date { day }
    var duration: TimeInterval { end.timeIntervalSince(start) }
    var hours: Double { duration / 3600 }
}

/// Estimation approximative : la nuit, on cherche la plus longue période où le rythme reste proche de
/// son niveau de repos. Sans capteur de mouvement fin ni phases de sommeil, ça reste une indication.
enum HealthEstimator {

    static func nights(from all: [Sample], now: Date = Date()) -> [SleepNight] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        var result: [SleepNight] = []

        for offset in 0..<7 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today),
                  let from = calendar.date(byAdding: .hour, value: -4, to: day),   // 20:00 la veille
                  let to = calendar.date(byAdding: .hour, value: 12, to: day) else { continue }
            let window = all
                .filter { $0.date >= from && $0.date <= to }
                .sorted { $0.t < $1.t }
            guard window.count >= 8 else { continue }

            let sorted = window.map { $0.b }.sorted()
            let resting = sorted[sorted.count / 5]
            let threshold = resting + 10

            var best: (Sample, Sample, Int)?
            var blockStart: Sample?
            var blockEnd: Sample?
            var blockCount = 0
            func close() {
                if let a = blockStart, let b = blockEnd {
                    let length = b.t - a.t
                    if best == nil || length > best!.1.t - best!.0.t { best = (a, b, blockCount) }
                }
                blockStart = nil
                blockEnd = nil
                blockCount = 0
            }
            for s in window {
                if s.b <= threshold {
                    if let last = blockEnd, s.t - last.t > 30 * 60 { close() }
                    if blockStart == nil { blockStart = s }
                    blockEnd = s
                    blockCount += 1
                } else {
                    close()
                }
            }
            close()

            if let (a, b, count) = best, count >= 5, b.t - a.t >= 3600 {
                result.append(SleepNight(day: day, start: a.date, end: b.date))
            }
        }
        return result.sorted { $0.day < $1.day }
    }

    /// Rythme au repos estimé sur les dernières 24 h (10e centile des mesures).
    static func restingHeartRate(from all: [Sample], now: Date = Date()) -> Int? {
        let cutoff = Int(now.timeIntervalSince1970) - 24 * 3600
        let values = all.filter { $0.t >= cutoff && $0.b > 0 }.map { $0.b }.sorted()
        guard values.count >= 20 else { return nil }
        return values[values.count / 10]
    }

    static func fitnessLabel(_ resting: Int) -> String {
        switch resting {
        case ..<55: return "Très bon"
        case ..<65: return "Bon"
        case ..<75: return "Moyen"
        default: return "Élevé"
        }
    }
}

struct SleepView: View {
    @ObservedObject var history: HistoryStore

    private var samples: [Sample] { history.sessions.flatMap { $0.samples } }

    var body: some View {
        NavigationStack {
            let nights = HealthEstimator.nights(from: samples)
            let resting = HealthEstimator.restingHeartRate(from: samples)
            List {
                Section {
                    if let resting {
                        LabeledContent("Rythme au repos", value: "\(resting) bpm")
                        LabeledContent("Forme (indicatif)", value: HealthEstimator.fitnessLabel(resting))
                    } else {
                        Text("Pas assez de mesures sur les dernières 24 h.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("État de forme")
                } footer: {
                    Text("Basé sur ton rythme cardiaque le plus bas de la journée. C'est une indication de forme, pas un avis médical.")
                }

                Section {
                    if nights.isEmpty {
                        Text("Pas encore de nuit détectée. Porte la montre la nuit avec une mesure régulière (toutes les 5 minutes suffit).")
                            .foregroundStyle(.secondary)
                    } else {
                        Chart(nights) { n in
                            BarMark(x: .value("Nuit", n.day, unit: .day),
                                    y: .value("Heures", n.hours))
                                .foregroundStyle(.indigo)
                        }
                        .frame(height: 160)
                        ForEach(nights.reversed()) { n in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(n.day.formatted(.dateTime.weekday(.wide).day().month()))
                                    .font(.subheadline.bold())
                                Text("\(n.start.formatted(date: .omitted, time: .shortened)) → \(n.end.formatted(date: .omitted, time: .shortened)) · \(formatDuration(n.duration))")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Sommeil estimé")
                } footer: {
                    Text("Estimation approximative : la plus longue période de la nuit où ton rythme reste proche du repos. Elle ne remplace pas les données de Samsung Health, auxquelles cette app n'a pas accès.")
                }
            }
            .navigationTitle("Santé")
        }
    }
}

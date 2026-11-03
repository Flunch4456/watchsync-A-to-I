import SwiftUI
import Charts

struct ActivityView: View {
    @ObservedObject var manager: HeartRateManager
    @ObservedObject var history: HistoryStore
    @AppStorage(SettingsKey.heightCm) private var heightCm = 175

    /// Longueur moyenne d'un pas : environ 41,5 % de la taille. C'est une estimation, pas une mesure.
    private var strideMeters: Double {
        Double(heightCm) * 0.415 / 100
    }

    private func kilometers(_ steps: Int) -> Double {
        Double(steps) * strideMeters / 1000
    }

    private var todaySteps: Int {
        manager.steps ?? history.todaySteps
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    todayCard
                    weekChart
                    batteryChart
                }
                .padding()
            }
            .navigationTitle("Activité")
        }
    }

    // MARK: - Aujourd'hui

    private var todayCard: some View {
        HStack(spacing: 12) {
            VStack(spacing: 2) {
                Text("\(todaySteps)")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Label("pas aujourd'hui", systemImage: "figure.walk")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 2) {
                Text(String(format: "%.2f", kilometers(todaySteps)))
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("km estimés")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 16)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Pas des 7 derniers jours

    private var weekChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pas des 7 derniers jours")
                .font(.headline)
            let week = history.weekSteps()
            Chart(week) { day in
                BarMark(
                    x: .value("Jour", day.date, unit: .day),
                    y: .value("Pas", day.steps)
                )
                .foregroundStyle(.red)
            }
            .frame(height: 180)
            Text("Distance estimée avec une taille de \(heightCm) cm (réglable dans Réglages). Les jours où la montre n'était pas connectée n'apparaissent pas.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Batterie de la montre

    private var batteryChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Batterie de la montre")
                .font(.headline)
            let cutoff = Int(Date().timeIntervalSince1970) - 48 * 3600
            let points = history.batteryLog.filter { $0.t >= cutoff }
            if points.count > 1 {
                Chart(points) { p in
                    LineMark(
                        x: .value("Heure", p.date),
                        y: .value("Batterie", p.b)
                    )
                    .foregroundStyle(.green)
                }
                .chartYScale(domain: 0...100)
                .frame(height: 180)
                Text("Les 48 dernières heures, relevées quand la montre est connectée.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("Pas encore assez de relevés. La courbe apparaît après quelques minutes de connexion.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

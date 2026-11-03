import SwiftUI
import Charts

struct LiveView: View {
    @ObservedObject var manager: HeartRateManager
    @ObservedObject var history: HistoryStore
    @State private var code = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "heart.fill")
                            .font(.title)
                            .foregroundStyle(.red)
                        Text(manager.bpm.map { String($0) } ?? "--")
                            .font(.system(size: 88, weight: .bold, design: .rounded))
                            .monospacedDigit()
                    }
                    Text("battements / minute")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Text(manager.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if let name = manager.connectedName {
                    connectedSection(name: name)
                } else {
                    pairingSection
                }
            }
            .padding()
        }
    }

    // MARK: - Montre connectée

    private func connectedSection(name: String) -> some View {
        VStack(spacing: 20) {
            HStack {
                Label(name, systemImage: "applewatch")
                Spacer()
                if let level = manager.battery {
                    Label("\(level) %", systemImage: batteryIcon(level))
                        .foregroundStyle(level <= 15 ? .red : .secondary)
                }
            }
            .font(.subheadline)

            if manager.needsCode {
                codeSection
            }

            if manager.authenticated && !manager.worn {
                Label("Montre retirée : pas de mesure cardiaque", systemImage: "applewatch.slash")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }

            if manager.syncing {
                Label("Récupération des mesures de la montre…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let stats = history.currentStats {
                HStack {
                    statBox("Min", stats.low)
                    statBox("Moyenne", stats.avg)
                    statBox("Max", stats.high)
                }
            }

            if history.live.count > 1 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Les 2 dernières minutes")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Chart(history.live) { s in
                        LineMark(
                            x: .value("Heure", s.date),
                            y: .value("BPM", s.b)
                        )
                        .foregroundStyle(.red)
                    }
                    .chartYScale(domain: yDomain(history.live))
                    .frame(height: 180)
                }
            }
        }
    }

    private var codeSection: some View {
        VStack(spacing: 10) {
            Text("Première liaison")
                .font(.headline)
            Text("Sur la montre, ouvre WatchLink puis touche « Lier l'iPhone ». Saisis ici le code à 6 chiffres affiché.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            TextField("000000", text: $code)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .font(.system(size: 32, weight: .bold, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .onChange(of: code) { value in
                    let digits = String(value.filter { $0.isNumber }.prefix(6))
                    if digits != value { code = digits }
                }
            if let error = manager.codeError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            Button("Lier") {
                manager.submitCode(code)
                code = ""
            }
            .buttonStyle(.borderedProminent)
            .disabled(code.count != 6)
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func statBox(_ title: String, _ value: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.title2.bold())
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func batteryIcon(_ level: Int) -> String {
        switch level {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }

    // MARK: - Recherche de la montre

    private var pairingSection: some View {
        VStack(spacing: 12) {
            ForEach(manager.found) { item in
                Button {
                    manager.connect(item.peripheral)
                } label: {
                    Label(item.name, systemImage: "dot.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
            }
            Button("Relancer la recherche") {
                manager.startScan()
            }
        }
    }
}

/// Plage verticale du graphique : marge de 10 bpm autour des valeurs.
func yDomain(_ samples: [Sample]) -> ClosedRange<Int> {
    guard let lo = samples.map({ $0.b }).min(), let hi = samples.map({ $0.b }).max() else {
        return 40...160
    }
    return Swift.max(30, lo - 10)...Swift.min(230, hi + 10)
}

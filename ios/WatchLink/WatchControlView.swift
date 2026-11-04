import SwiftUI

/// Réglages de la montre depuis l'iPhone : luminosité, durée d'écran, ne pas déranger, économie d'énergie.
struct WatchControlView: View {
    @ObservedObject var manager: HeartRateManager
    @State private var brightness = 128.0
    @State private var auto = false
    @State private var timeout = 30
    @State private var dnd = false
    @State private var saver = false
    @State private var waited = false

    var body: some View {
        Form {
            stateSection
            controlsSection
            Section {
                Text("Ces réglages demandent une autorisation à donner une seule fois sur la montre, en ADB :")
                    .font(.footnote)
                Text("adb shell appops set fr.nino.watchlink WRITE_SETTINGS allow\nadb shell cmd notification allow_dnd fr.nino.watchlink\nadb shell pm grant fr.nino.watchlink android.permission.WRITE_SECURE_SETTINGS")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            } header: {
                Text("Autorisations")
            } footer: {
                Text("Sans l'autorisation, la montre affiche en statut la commande qui manque.")
            }
        }
        .navigationTitle("Contrôle de la montre")
        .onAppear {
            manager.requestInfo()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { waited = true }
        }
        .onChange(of: manager.watchInfo?.brightness) { value in
            if let value { brightness = Double(Swift.max(1, value)) }
        }
    }

    private var stateSection: some View {
        Section {
            if let info = manager.watchInfo {
                LabeledContent("Modèle", value: manager.watchModel ?? "…")
                LabeledContent("App sur la montre", value: manager.watchVersion ?? "…")
                LabeledContent("Système", value: info.androidVersion)
                LabeledContent("Batterie", value: "\(manager.battery ?? 0) %" + (info.charging ? " (en charge)" : ""))
                LabeledContent("Température batterie", value: String(format: "%.1f °C", info.temperature))
                LabeledContent("Stockage libre", value: info.freeMB >= 1024
                               ? String(format: "%.1f Go", Double(info.freeMB) / 1024)
                               : "\(info.freeMB) Mo")
                LabeledContent("Allumée depuis", value: info.uptimeHours >= 48
                               ? "\(info.uptimeHours / 24) jours" : "\(info.uptimeHours) h")
                LabeledContent("Au poignet", value: info.worn ? "Oui" : "Non")
                LabeledContent("Ne pas déranger", value: info.dnd ? "Activé" : "Désactivé")
                LabeledContent("Économie d'énergie", value: info.saver ? "Activée" : "Désactivée")
            } else {
                if !manager.authenticated {
                    Text("Montre non connectée.").foregroundStyle(.secondary)
                } else if waited {
                    Text("La montre ne répond pas à cette demande. Vérifie que l'APK installé sur la montre est bien la version 0.9.0 ou plus récente, puis touche Actualiser.")
                        .foregroundStyle(.orange)
                } else {
                    Text("Lecture de l'état de la montre…").foregroundStyle(.secondary)
                }
            }
            Button {
                waited = false
                manager.requestInfo()
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { waited = true }
            } label: {
                Label("Actualiser", systemImage: "arrow.clockwise")
            }
            .disabled(!manager.authenticated)
        } header: {
            Text("État de la montre")
        }
    }

    private var controlsSection: some View {
        Section {
            Toggle("Luminosité automatique", isOn: $auto)
            VStack(alignment: .leading) {
                Text("Luminosité : \(Int(brightness))")
                Slider(value: $brightness, in: 1...255, step: 1)
                    .disabled(auto)
            }
            Button("Appliquer la luminosité") {
                manager.setBrightness(Int(brightness), auto: auto)
            }
            Picker("Écran allumé pendant", selection: $timeout) {
                Text("15 secondes").tag(15)
                Text("30 secondes").tag(30)
                Text("1 minute").tag(60)
                Text("2 minutes").tag(120)
                Text("5 minutes").tag(300)
            }
            Button("Appliquer la durée") {
                manager.setScreenTimeout(timeout)
            }
            Toggle("Ne pas déranger", isOn: $dnd)
                .onChange(of: dnd) { manager.setDnd($0) }
            Toggle("Économie d'énergie", isOn: $saver)
                .onChange(of: saver) { manager.setPowerSaver($0) }
        } header: {
            Text("Réglages")
        }
        .disabled(!manager.authenticated)
    }
}

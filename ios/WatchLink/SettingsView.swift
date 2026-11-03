import SwiftUI

struct SettingsView: View {
    @ObservedObject var manager: HeartRateManager

    @AppStorage(SettingsKey.alertEnabled) private var alertEnabled = false
    @AppStorage(SettingsKey.alertLow) private var alertLow = 50
    @AppStorage(SettingsKey.alertHigh) private var alertHigh = 130
    @AppStorage(SettingsKey.alertVibrate) private var alertVibrate = true
    @AppStorage(SettingsKey.alertPhone) private var alertPhone = true
    @AppStorage(SettingsKey.autostart) private var autostart = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Activer les alertes", isOn: $alertEnabled)
                    Stepper("Seuil bas : \(alertLow) bpm", value: $alertLow, in: 30...120)
                        .disabled(!alertEnabled)
                    Stepper("Seuil haut : \(alertHigh) bpm", value: $alertHigh, in: 100...220)
                        .disabled(!alertEnabled)
                    Toggle("Faire vibrer la montre", isOn: $alertVibrate)
                        .disabled(!alertEnabled)
                    Toggle("Notifier sur l'iPhone", isOn: $alertPhone)
                        .disabled(!alertEnabled)
                } header: {
                    Text("Alertes de rythme")
                } footer: {
                    Text("Une alerte par minute au maximum quand le rythme sort de la plage. Les réglages sont envoyés à la montre dès qu'elle est connectée.")
                }

                Section("Montre") {
                    Toggle("Démarrage automatique", isOn: $autostart)

                    if let level = manager.battery {
                        LabeledContent("Batterie", value: "\(level) %")
                    }

                    Button {
                        manager.toggleRing()
                    } label: {
                        Label(manager.ringing ? "Arrêter la sonnerie" : "Faire sonner la montre",
                              systemImage: manager.ringing ? "bell.slash.fill" : "bell.and.waves.left.and.right.fill")
                    }
                    .disabled(!manager.controlAvailable)
                }

                Section {
                    Text("L'affichage des notifications de l'iPhone sur la montre arrive à l'étape suivante. Le réglage pour l'activer ou le désactiver sera ici.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Notifications sur la montre")
                }

                if manager.connectedName != nil {
                    Section {
                        Button("Oublier cette montre", role: .destructive) {
                            manager.forget()
                        }
                    }
                }
            }
            .navigationTitle("Réglages")
            .onChange(of: alertEnabled) { enabled in
                if enabled { manager.requestNotificationPermission() }
                manager.sendConfig()
            }
            .onChange(of: alertLow) { _ in manager.sendConfig() }
            .onChange(of: alertHigh) { _ in manager.sendConfig() }
            .onChange(of: alertVibrate) { _ in manager.sendConfig() }
            .onChange(of: alertPhone) { _ in manager.sendConfig() }
            .onChange(of: autostart) { _ in manager.sendConfig() }
        }
    }
}

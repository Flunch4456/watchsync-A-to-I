import SwiftUI

struct SettingsView: View {
    @ObservedObject var manager: HeartRateManager

    @AppStorage(SettingsKey.alertEnabled) private var alertEnabled = false
    @AppStorage(SettingsKey.alertLow) private var alertLow = 50
    @AppStorage(SettingsKey.alertHigh) private var alertHigh = 130
    @AppStorage(SettingsKey.alertVibrate) private var alertVibrate = true
    @AppStorage(SettingsKey.alertPhone) private var alertPhone = true
    @AppStorage(SettingsKey.autostart) private var autostart = true
    @AppStorage(SettingsKey.hrInterval) private var hrInterval = 1
    @AppStorage(SettingsKey.heightCm) private var heightCm = 175
    @AppStorage(SettingsKey.offWristNotify) private var offWristNotify = true
    @AppStorage(SettingsKey.mirrorNotifications) private var mirror = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Fréquence", selection: $hrInterval) {
                        Text("En continu (chaque seconde)").tag(1)
                        Text("Toutes les 10 secondes").tag(10)
                        Text("Toutes les 30 secondes").tag(30)
                        Text("Toutes les minutes").tag(60)
                        Text("Toutes les 5 minutes").tag(300)
                        Text("Toutes les 15 minutes").tag(900)
                        Text("Désactivée").tag(0)
                    }
                } header: {
                    Text("Mesure cardiaque")
                } footer: {
                    Text("Le capteur est ce qui consomme le plus de batterie. Plus l'intervalle est long, plus la montre tient longtemps. Entre deux mesures, la dernière valeur reste affichée.")
                }

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

                Section {
                    Toggle("Notifier si la montre est retirée", isOn: $offWristNotify)
                } header: {
                    Text("Port de la montre")
                } footer: {
                    Text("Quand la montre n'est plus au poignet, elle arrête la mesure cardiaque et l'iPhone te prévient.")
                }

                Section("Activité") {
                    Stepper("Taille : \(heightCm) cm", value: $heightCm, in: 100...230)
                }

                Section {
                    Toggle("Démarrage automatique", isOn: $autostart)

                    if let level = manager.battery {
                        LabeledContent("Batterie", value: "\(level) %")
                    }

                    Button {
                        manager.startRing()
                    } label: {
                        Label("Faire sonner la montre", systemImage: "bell.and.waves.left.and.right.fill")
                    }
                    .disabled(!manager.controlAvailable)

                    Button {
                        manager.startVibrate()
                    } label: {
                        Label("Faire vibrer la montre", systemImage: "waveform")
                    }
                    .disabled(!manager.controlAvailable)

                    Button(role: .destructive) {
                        manager.stopAlert()
                    } label: {
                        Label("Annuler la sonnerie / vibration", systemImage: "bell.slash.fill")
                    }
                    .disabled(!manager.controlAvailable || manager.watchAlert == .none)
                } header: {
                    Text("Montre")
                } footer: {
                    Text("La sonnerie et la vibration s'arrêtent seules au bout d'une minute.")
                }

                Section {
                    Toggle("Afficher les notifications de l'iPhone", isOn: $mirror)
                } header: {
                    Text("Notifications sur la montre")
                } footer: {
                    Text("Au premier essai, iOS demande d'appairer la montre : accepte. Puis dans Réglages iOS > Bluetooth > (i) à côté de la montre, active « Partager les notifications du système ». Sans ça, iOS ne les transmet pas.")
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
            .onChange(of: hrInterval) { _ in manager.sendConfig() }
            .onChange(of: mirror) { _ in manager.sendConfig() }
        }
    }
}

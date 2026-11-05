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
    @AppStorage(SettingsKey.ageYears) private var age = 25
    @AppStorage(SettingsKey.weightKg) private var weightKg = 70
    @AppStorage(SettingsKey.stepGoal) private var stepGoal = 8000
    @AppStorage(SettingsKey.stepGoalNotify) private var stepGoalNotify = true
    @AppStorage(SettingsKey.moveMinutes) private var moveMinutes = 0
    @AppStorage(SettingsKey.quietEnabled) private var quietEnabled = false
    @AppStorage(SettingsKey.quietStart) private var quietStart = 22
    @AppStorage(SettingsKey.quietEnd) private var quietEnd = 7
    @AppStorage(SettingsKey.appMask) private var appMask = 65535
    @AppStorage(SettingsKey.batteryAlert) private var batteryAlert = true
    @AppStorage(SettingsKey.batteryAlertLevel) private var batteryAlertLevel = 15
    @AppStorage(SettingsKey.disconnectAlert) private var disconnectAlert = true
    @State private var exportURL: URL?

    private static let appNames = ["Messages", "Téléphone", "Mail", "WhatsApp", "Instagram", "Snapchat",
                                   "Telegram", "Messenger", "Discord", "TikTok", "Gmail", "Teams / Skype"]

    /// Applique le changement puis renvoie les réglages à la montre.
    private func synced<T>(_ binding: Binding<T>) -> Binding<T> {
        Binding(get: { binding.wrappedValue },
                set: { binding.wrappedValue = $0; manager.sendConfig() })
    }

    private func appBinding(_ bit: Int) -> Binding<Bool> {
        Binding(get: { (appMask >> bit) & 1 == 1 },
                set: { on in
                    appMask = on ? (appMask | (1 << bit)) : (appMask & ~(1 << bit))
                    manager.sendConfig()
                })
    }

    private var profileSection: some View {
        Section {
            Stepper("Âge : \(age) ans", value: $age, in: 10...90)
            Stepper("Poids : \(weightKg) kg", value: $weightKg, in: 30...200)
            Stepper("Objectif : \(stepGoal) pas", value: $stepGoal, in: 1000...30000, step: 500)
            Toggle("Notifier quand l'objectif est atteint", isOn: $stepGoalNotify)
        } header: {
            Text("Profil et objectifs")
        } footer: {
            Text("L'âge sert aux zones cardiaques (rythme maximal = 220 − âge), le poids aux calories.")
        }
    }

    private var moveSection: some View {
        Section {
            Picker("Rappel de bouger", selection: synced($moveMinutes)) {
                Text("Désactivé").tag(0)
                Text("Après 30 min sans marcher").tag(30)
                Text("Après 45 min").tag(45)
                Text("Après 1 h").tag(60)
                Text("Après 1 h 30").tag(90)
            }
        } header: {
            Text("Rappel de bouger")
        } footer: {
            Text("La montre vibre entre 8 h et 22 h si tu n'as pas marché depuis ce temps. Elle ne le fait pas si elle est retirée du poignet.")
        }
    }

    private var quietSection: some View {
        Section {
            Toggle("Activer les heures calmes", isOn: synced($quietEnabled))
            Stepper("De \(quietStart) h", value: synced($quietStart), in: 0...23)
                .disabled(!quietEnabled)
            Stepper("À \(quietEnd) h", value: synced($quietEnd), in: 0...23)
                .disabled(!quietEnabled)
        } header: {
            Text("Heures calmes")
        } footer: {
            Text("Pendant ces heures, les notifications de l'iPhone arrivent sans pop-up ni vibration et les rappels sont coupés. Les alertes de rythme cardiaque restent actives.")
        }
    }

    private var appsSection: some View {
        Section {
            ForEach(0..<Self.appNames.count, id: \.self) { i in
                Toggle(Self.appNames[i], isOn: appBinding(i))
            }
            Toggle("Toutes les autres apps", isOn: appBinding(15))
        } header: {
            Text("Apps affichées sur la montre")
        } footer: {
            Text("Ne concerne que les notifications de l'iPhone envoyées à la montre (réglage ci-dessus).")
        }
    }

    private var connectionSection: some View {
        Section {
            Toggle("Alerte si la batterie de la montre est faible", isOn: $batteryAlert)
            Stepper("Seuil : \(batteryAlertLevel) %", value: $batteryAlertLevel, in: 5...50, step: 5)
                .disabled(!batteryAlert)
            Toggle("Alerte si la montre se déconnecte", isOn: $disconnectAlert)
        } header: {
            Text("Alertes de la montre")
        } footer: {
            Text("L'alerte de déconnexion part si la montre reste injoignable plus d'une minute.")
        }
    }

    private var dataSection: some View {
        Section {
            Button {
                exportURL = manager.history.exportAllJSON()
            } label: {
                Label("Préparer l'export complet (JSON)", systemImage: "square.and.arrow.up")
            }
            if let url = exportURL {
                ShareLink(item: url) {
                    Label("Partager le fichier", systemImage: "doc")
                }
            }
        } header: {
            Text("Données")
        } footer: {
            Text("Rythme cardiaque, pas par jour et batterie des 7 derniers jours dans un seul fichier.")
        }
    }

    private var controlSection: some View {
        Section {
            NavigationLink {
                WatchControlView(manager: manager)
            } label: {
                Label("Contrôle de la montre", systemImage: "applewatch.watchface")
            }
            NavigationLink {
                RemoteScreenView(manager: manager)
            } label: {
                Label("Écran de la montre à distance", systemImage: "rectangle.on.rectangle")
            }
            UpdateLinkRow(manager: manager, updater: manager.updater)
        } footer: {
            Text("État détaillé de la montre, luminosité, durée d'écran, ne pas déranger, économie d'énergie, mises à jour depuis GitHub.")
        }
    }

    @ViewBuilder
    private var extraSections: some View {
        controlSection
        profileSection
        moveSection
        quietSection
        appsSection
        connectionSection
        dataSection
    }

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

                extraSections

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

import SwiftUI

/// Ligne du menu Réglages : affiche une pastille quand une version plus récente existe sur GitHub.
struct UpdateLinkRow: View {
    @ObservedObject var manager: HeartRateManager
    @ObservedObject var updater: UpdateManager

    var body: some View {
        NavigationLink {
            UpdateView(manager: manager, updater: updater)
        } label: {
            HStack {
                Label("Mises à jour", systemImage: "arrow.down.circle")
                Spacer()
                if updater.watchUpdateAvailable || updater.phoneUpdateAvailable {
                    Text("Nouvelle version")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.accentColor, in: Capsule())
                        .foregroundStyle(.white)
                }
            }
        }
    }
}

struct UpdateView: View {
    @ObservedObject var manager: HeartRateManager
    @ObservedObject var updater: UpdateManager

    @AppStorage(UpdateKey.autoCheck) private var autoCheck = true
    @AppStorage(UpdateKey.autoInstall) private var autoInstall = false

    private var installedOnWatch: String {
        manager.watchVersion ?? "inconnue"
    }

    var body: some View {
        Form {
            versionsSection
            watchSection
            phoneSection
            settingsSection
            if let notes = updater.latest?.notes, !notes.isEmpty {
                Section("Nouveautés de la version \(updater.latest?.version ?? "")") {
                    Text(notes)
                        .font(.footnote)
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Mises à jour")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { updater.autoCheckIfNeeded() }
    }

    // MARK: - Sections

    private var versionsSection: some View {
        Section {
            row("App iPhone", updater.phoneVersion)
            row("App montre", installedOnWatch)
            row("Dernière version sur GitHub", updater.latest?.version ?? "pas encore vérifiée")
            if let date = updater.lastChecked {
                row("Dernière vérification", date.formatted(date: .omitted, time: .shortened))
            }
            Button {
                updater.check()
            } label: {
                HStack {
                    Label("Vérifier maintenant", systemImage: "arrow.clockwise")
                    if updater.phase == .checking {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(updater.phase.isBusy)
        } header: {
            Text("Versions")
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var watchSection: some View {
        Section {
            switch updater.phase {
            case .idle, .checking:
                watchIdleContent
            case .downloading:
                progressRow("Téléchargement depuis GitHub…", value: nil)
                cancelButton
            case .waitingWatch:
                progressRow("Préparation de la montre…", value: nil)
                cancelButton
            case .sending:
                progressRow("Envoi à la montre…", value: updater.progress)
                cancelButton
            case .verifying:
                progressRow("La montre vérifie le fichier…", value: nil)
            case .installing:
                progressRow("Installation sur la montre. Elle va redémarrer l'app.", value: nil)
                cancelButton
            case .confirm:
                Label("Confirme l'installation sur la montre : touche la notification « Mise à jour de WatchLink ».",
                      systemImage: "hand.tap")
                cancelButton
            case .success:
                Label("La montre est à jour (version \(installedOnWatch)).", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                if updater.latest != nil {
                    Button("Réessayer") { updater.updateWatch() }
                        .disabled(!manager.authenticated)
                }
            }
        } header: {
            Text("Montre")
        } footer: {
            Text("L'iPhone télécharge l'APK de la dernière version sur GitHub, vérifie son empreinte, l'envoie à la montre en Bluetooth, et la montre l'installe toute seule. Elle n'accepte que les fichiers signés avec la même clé que l'app installée.")
        }
    }

    @ViewBuilder
    private var watchIdleContent: some View {
        if !manager.authenticated {
            Label("La montre n'est pas connectée.", systemImage: "applewatch.slash")
                .foregroundStyle(.secondary)
        } else if updater.latest == nil {
            Text("Touche « Vérifier maintenant » pour chercher une version.")
                .foregroundStyle(.secondary)
        } else if updater.watchUpdateAvailable, let latest = updater.latest {
            Button {
                updater.updateWatch()
            } label: {
                Label("Mettre à jour la montre vers \(latest.version)", systemImage: "arrow.down.circle.fill")
            }
        } else if manager.watchVersion == nil {
            Text("Version de la montre inconnue. Elle est lue à la connexion : réessaie dans un instant.")
                .foregroundStyle(.secondary)
        } else {
            Label("La montre est à jour.", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        }
    }

    private func progressRow(_ title: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
            if let value {
                ProgressView(value: value)
                Text("\(Int(value * 100)) %")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
    }

    private var cancelButton: some View {
        Button("Annuler", role: .destructive) { updater.cancel() }
    }

    @ViewBuilder
    private var phoneSection: some View {
        if let latest = updater.latest {
            Section {
                if updater.phoneUpdateAvailable {
                    Label("Une version \(latest.version) de l'app iPhone existe.", systemImage: "iphone.gen3")
                    if let ipa = latest.ipa {
                        Link(destination: ipa) {
                            Label("Télécharger le fichier .ipa", systemImage: "arrow.down.doc")
                        }
                    }
                } else {
                    Label("L'app iPhone est à jour.", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                }
                Link(destination: latest.page) {
                    Label("Ouvrir la page de la version sur GitHub", systemImage: "safari")
                }
            } header: {
                Text("iPhone")
            } footer: {
                Text("iOS interdit à une app de se remplacer elle-même. Pour l'iPhone : télécharge le .ipa, puis ouvre-le dans SideStore (Partager > SideStore) pour l'installer par-dessus.")
            }
        }
    }

    private var settingsSection: some View {
        Section {
            Toggle("Vérifier automatiquement", isOn: $autoCheck)
            Toggle("Installer seule sur la montre", isOn: $autoInstall)
                .disabled(!autoCheck)
        } header: {
            Text("Automatique")
        } footer: {
            Text("La vérification a lieu au plus toutes les 6 heures, quand l'app s'ouvre ou que la montre se connecte, et une notification t'avertit d'une nouvelle version. « Installer seule » envoie la mise à jour à la montre dès qu'elle est connectée, sans rien demander ; désactivé par défaut.")
        }
    }
}

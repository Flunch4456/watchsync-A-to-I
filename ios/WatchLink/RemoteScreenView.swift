import SwiftUI

/// Voir et commander l'écran de la montre depuis l'iPhone : touche pour toucher, glisse pour faire défiler.
struct RemoteScreenView: View {
    @ObservedObject var manager: HeartRateManager
    @State private var quality = 1
    @State private var noAnswer = false

    private static let presets: [(String, Int, Int)] = [
        ("Rapide", 240, 55),
        ("Équilibrée", 320, 65),
        ("Nette", 400, 80)
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                screen
                navigation
                settings
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
        .navigationTitle("Écran de la montre")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { manager.remoteStop() }
    }

    private var active: Bool { manager.remoteState == 1 }

    private var footer: String {
        if noAnswer && manager.remoteState == 0 {
            return "La montre n'a pas répondu. Vérifie que l'APK installé sur la montre est bien la version 0.9.0 ou plus récente (visible dans Contrôle de la montre), et que la montre est connectée."
        }
        switch manager.remoteState {
        case 1: return "Quelques images par seconde. L'écran de la montre reste allumé et l'affichage s'arrête seul au bout de 5 minutes."
        case 2: return "Impossible de démarrer : autorise d'abord la montre avec adb shell pm grant fr.nino.watchlink android.permission.WRITE_SECURE_SETTINGS, puis réessaie."
        default: return "L'écran s'affiche ici en images fixes rafraîchies plusieurs fois par seconde, ce n'est pas de la vidéo. « Nette » utilise la résolution complète de la montre. Ça consomme de la batterie : arrête quand tu as fini."
        }
    }

    private var screen: some View {
        GeometryReader { geo in
            let width = geo.size.width
            if let image = manager.screenImage {
                let height = width * image.size.height / Swift.max(image.size.width, 1)
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onEnded { value in
                                handle(value, width: width, height: height)
                            }
                    )
            } else {
                RoundedRectangle(cornerRadius: 24)
                    .fill(.quaternary)
                    .frame(width: width, height: width)
                    .overlay {
                        Text(active ? "Attente de l'image…" : "Écran éteint")
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func handle(_ value: DragGesture.Value, width: CGFloat, height: CGFloat) {
        let start = (Double(value.startLocation.x / width), Double(value.startLocation.y / height))
        let end = (Double(value.location.x / width), Double(value.location.y / height))
        let dx = value.location.x - value.startLocation.x
        let dy = value.location.y - value.startLocation.y
        if (dx * dx + dy * dy).squareRoot() < 12 {
            manager.remoteTap(x: end.0, y: end.1)
        } else {
            let distance = Double((dx * dx + dy * dy).squareRoot())
            let ms = Int(Swift.min(600, Swift.max(150, distance * 2)))
            manager.remoteSwipe(from: start, to: end, durationMs: ms)
        }
    }

    private var navigation: some View {
        HStack(spacing: 12) {
            Button { manager.remoteNavigate(0) } label: { Label("Retour", systemImage: "chevron.backward") }
            Button { manager.remoteNavigate(1) } label: { Label("Accueil", systemImage: "circle") }
            Button { manager.remoteNavigate(2) } label: { Label("Récentes", systemImage: "square.on.square") }
        }
        .buttonStyle(.bordered)
        .labelStyle(.titleAndIcon)
        .font(.footnote)
        .disabled(!active)
    }

    private var settings: some View {
        VStack(spacing: 12) {
            Picker("Qualité", selection: $quality) {
                ForEach(0..<Self.presets.count, id: \.self) { i in
                    Text(Self.presets[i].0).tag(i)
                }
            }
            .pickerStyle(.segmented)
            .disabled(active)

            if active {
                Button(role: .destructive) {
                    manager.remoteStop()
                } label: {
                    Label("Arrêter", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    let preset = Self.presets[quality]
                    noAnswer = false
                    manager.remoteStart(side: preset.1, quality: preset.2)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { noAnswer = true }
                } label: {
                    Label("Afficher l'écran de la montre", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!manager.authenticated)
            }
        }
    }
}

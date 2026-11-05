import CoreBluetooth
import CryptoKit
import Foundation
import UserNotifications

/// Une version publiée sur GitHub (onglet Releases du dépôt).
struct ReleaseInfo {
    let version: String
    let page: URL
    let apk: URL
    let apkSize: Int
    let apkDigest: String?   // « sha256:… » fourni par GitHub
    let ipa: URL?
    let notes: String
}

enum UpdatePhase: Equatable {
    case idle
    case checking
    case downloading
    case waitingWatch
    case sending
    case verifying
    case installing
    case confirm
    case success
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .idle, .success, .failed: return false
        default: return true
        }
    }
}

/// Réglages des mises à jour (partagés avec l'écran via @AppStorage).
enum UpdateKey {
    static let autoCheck = "updateAutoCheck"
    static let autoInstall = "updateAutoInstallWatch"
    static let lastCheck = "updateLastCheck"
    static let notified = "updateNotifiedVersion"
}

/// Vérifie la dernière version sur GitHub, la télécharge et l'envoie à la montre, qui l'installe.
/// La montre vérifie elle-même l'empreinte SHA-256 reçue, et Android refuse tout APK qui n'est pas signé avec la même clé.
final class UpdateManager: ObservableObject {

    static let repo = "Flunch4456/watchsync-A-to-I"

    @Published var latest: ReleaseInfo?
    @Published var phase: UpdatePhase = .idle
    @Published var progress = 0.0
    @Published var lastChecked: Date?

    weak var manager: HeartRateManager?
    private var payload = Data()
    private var channel: UpdateChannel?
    private var attempt = 0
    private var targetVersion: String?

    var phoneVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    init() {
        UserDefaults.standard.register(defaults: [
            UpdateKey.autoCheck: true,
            UpdateKey.autoInstall: false
        ])
    }

    // MARK: - Versions

    static func parse(_ v: String) -> [Int] {
        v.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            .split(separator: ".")
            .map { Int($0) ?? 0 }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = parse(a)
        let y = parse(b)
        for i in 0..<Swift.max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0
            let q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    var watchUpdateAvailable: Bool {
        guard let latest, let installed = manager?.watchVersion else { return false }
        return Self.isNewer(latest.version, than: installed)
    }

    var phoneUpdateAvailable: Bool {
        guard let latest else { return false }
        return Self.isNewer(latest.version, than: phoneVersion)
    }

    private func onMain(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }

    // MARK: - Vérification sur GitHub

    private struct GitHubAsset: Decodable {
        let name: String
        let browserDownloadUrl: URL
        let size: Int
        let digest: String?
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlUrl: URL
        let body: String?
        let assets: [GitHubAsset]
    }

    private static func fetchLatest() async throws -> ReleaseInfo {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("WatchLink-iOS", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "WatchLink", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "GitHub a répondu avec une erreur"])
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let release = try decoder.decode(GitHubRelease.self, from: data)
        guard let apk = release.assets.first(where: { $0.name.hasSuffix(".apk") }) else {
            throw NSError(domain: "WatchLink", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Aucun APK dans la dernière version"])
        }
        let ipa = release.assets.first(where: { $0.name.hasSuffix(".ipa") })
        return ReleaseInfo(version: release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV")),
                           page: release.htmlUrl,
                           apk: apk.browserDownloadUrl,
                           apkSize: apk.size,
                           apkDigest: apk.digest,
                           ipa: ipa?.browserDownloadUrl,
                           notes: release.body ?? "")
    }

    /// `silent` : vérification automatique, sans message d'erreur ni changement d'écran.
    func check(silent: Bool = false) {
        guard !phase.isBusy else { return }
        if !silent { phase = .checking }
        Task {
            do {
                let info = try await Self.fetchLatest()
                self.onMain {
                    self.latest = info
                    self.lastChecked = Date()
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: UpdateKey.lastCheck)
                    if !silent { self.phase = .idle }
                    self.afterCheck(info, silent: silent)
                }
            } catch {
                if !silent {
                    self.onMain { self.phase = .failed("Impossible de joindre GitHub : \(error.localizedDescription)") }
                }
            }
        }
    }

    /// Appelé à l'ouverture de l'app et à la connexion de la montre : une vérification toutes les 6 heures au plus.
    func autoCheckIfNeeded() {
        let d = UserDefaults.standard
        guard d.bool(forKey: UpdateKey.autoCheck), !phase.isBusy else { return }
        let last = d.double(forKey: UpdateKey.lastCheck)
        guard Date().timeIntervalSince1970 - last > 6 * 3600 else { return }
        check(silent: true)
    }

    private func afterCheck(_ info: ReleaseInfo, silent: Bool) {
        let d = UserDefaults.standard
        let newerForWatch = watchUpdateAvailable
        if (newerForWatch || phoneUpdateAvailable), d.string(forKey: UpdateKey.notified) != info.version {
            d.set(info.version, forKey: UpdateKey.notified)
            let content = UNMutableNotificationContent()
            content.title = "Mise à jour WatchLink disponible"
            content.body = "La version \(info.version) est disponible. Ouvre Réglages > Mises à jour."
            content.sound = .default
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "update-available", content: content, trigger: nil))
        }
        if newerForWatch, d.bool(forKey: UpdateKey.autoInstall), manager?.authenticated == true {
            updateWatch()
        }
    }

    // MARK: - Envoi à la montre

    func updateWatch() {
        guard let info = latest, !phase.isBusy else { return }
        guard let manager, manager.authenticated else {
            phase = .failed("La montre n'est pas connectée.")
            return
        }
        attempt += 1
        let mine = attempt
        targetVersion = info.version
        progress = 0
        phase = .downloading
        Task {
            do {
                var request = URLRequest(url: info.apk)
                request.setValue("WatchLink-iOS", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
                    throw NSError(domain: "WatchLink", code: 3,
                                  userInfo: [NSLocalizedDescriptionKey: "Téléchargement refusé"])
                }
                let hash = Data(SHA256.hash(data: data))
                // GitHub publie l'empreinte du fichier : on vérifie qu'on a bien reçu le bon
                if let expected = info.apkDigest?.replacingOccurrences(of: "sha256:", with: ""),
                   expected.lowercased() != hash.map({ String(format: "%02x", $0) }).joined() {
                    throw NSError(domain: "WatchLink", code: 4,
                                  userInfo: [NSLocalizedDescriptionKey: "Le fichier téléchargé ne correspond pas à l'empreinte de GitHub"])
                }
                self.onMain {
                    guard mine == self.attempt else { return }
                    self.payload = hash + data
                    self.phase = .waitingWatch
                    manager.beginWatchUpdate(size: data.count)
                    // La montre doit répondre dans les 25 secondes
                    DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
                        if mine == self.attempt, self.phase == .waitingWatch {
                            manager.cancelWatchUpdate()
                            self.phase = .failed("La montre n'a pas répondu. Vérifie qu'elle est connectée et que l'APK installé est la version 0.10.0 ou plus récente.")
                        }
                    }
                }
            } catch {
                self.onMain {
                    guard mine == self.attempt else { return }
                    self.phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    func cancel() {
        attempt += 1
        channel?.close()
        channel = nil
        manager?.cancelWatchUpdate()
        phase = .idle
    }

    /// La montre a ouvert son canal : on y envoie [empreinte][APK].
    func channelOpened(_ l2cap: CBL2CAPChannel) {
        guard phase == .waitingWatch else {
            return
        }
        phase = .sending
        let mine = attempt
        channel = UpdateChannel(
            channel: l2cap,
            payload: payload,
            onProgress: { [weak self] value in
                guard let self, mine == self.attempt else { return }
                // Évite de redessiner l'écran à chaque paquet de 8 Ko
                if value >= 1 || value - self.progress >= 0.01 { self.progress = value }
            },
            onAck: { [weak self] ok in
                guard let self, mine == self.attempt else { return }
                if ok {
                    self.phase = .installing
                } else {
                    self.phase = .failed("Le fichier a été abîmé pendant le transfert. Réessaie.")
                }
            },
            onClose: { [weak self] in
                guard let self, mine == self.attempt else { return }
                self.channel = nil
                if self.phase == .sending {
                    self.phase = .failed("Le transfert a été interrompu. Réessaie.")
                }
            })
    }

    /// Étapes envoyées par la montre : voir updateStage() dans l'app montre.
    func watchStage(_ stage: Int, detail: Int) {
        switch stage {
        case 3: phase = .verifying
        case 4: phase = .installing
        case 5: phase = .confirm
        case 6:
            let reason: String
            switch detail {
            case 1: reason = "empreinte incorrecte"
            case 2: reason = "erreur de réception ou pas assez de place"
            case 3: reason = "l'installation n'a pas pu démarrer"
            case 4: reason = "l'iPhone n'a pas ouvert le canal à temps"
            case 17: reason = "signature différente : désinstalle l'app sur la montre une fois (adb uninstall fr.nino.watchlink), puis installe l'APK à la main"
            default: reason = "code \(detail)"
            }
            if phase.isBusy { phase = .failed("La montre a refusé la mise à jour : \(reason).") }
        case 7:
            phase = .failed("La montre n'a pas l'autorisation d'installer. Une seule fois, sur le PC : adb shell appops set fr.nino.watchlink REQUEST_INSTALL_PACKAGES allow")
        case 0:
            if phase.isBusy { phase = .idle }
        default:
            break
        }
    }

    /// La montre se reconnecte après son redémarrage : si elle annonce la nouvelle version, c'est réussi.
    func watchVersionChanged(_ version: String?) {
        objectWillChange.send()
        guard let version, let target = targetVersion, phase.isBusy || phase == .confirm else { return }
        if !Self.isNewer(target, than: version) {
            phase = .success
            targetVersion = nil
        }
    }
}

// MARK: - Canal d'envoi (L2CAP)

/// Écrit l'empreinte et l'APK sur le canal ouvert par la montre, en respectant le débit qu'elle peut absorber,
/// puis lit l'octet de réponse : 1 = reçu intact, 0 = corrompu.
final class UpdateChannel: NSObject, StreamDelegate {
    private let channel: CBL2CAPChannel
    private let payload: Data
    private var offset = 0
    private var closed = false
    private let onProgress: (Double) -> Void
    private let onAck: (Bool) -> Void
    private let onClose: () -> Void

    init(channel: CBL2CAPChannel, payload: Data,
         onProgress: @escaping (Double) -> Void,
         onAck: @escaping (Bool) -> Void,
         onClose: @escaping () -> Void) {
        self.channel = channel
        self.payload = payload
        self.onProgress = onProgress
        self.onAck = onAck
        self.onClose = onClose
        super.init()
        for stream in streams {
            stream.delegate = self
            stream.schedule(in: .main, forMode: .default)
            stream.open()
        }
    }

    private var streams: [Stream] {
        [channel.inputStream, channel.outputStream]
    }

    func close() {
        guard !closed else { return }
        closed = true
        for stream in streams {
            stream.delegate = nil
            stream.remove(from: .main, forMode: .default)
            stream.close()
        }
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .hasSpaceAvailable:
            writeMore()
        case .hasBytesAvailable:
            var byte: UInt8 = 0
            if channel.inputStream.read(&byte, maxLength: 1) == 1 {
                onAck(byte == 1)
                close()
            }
        case .endEncountered, .errorOccurred:
            close()
            onClose()
        default:
            break
        }
    }

    private func writeMore() {
        guard !closed else { return }
        while offset < payload.count && channel.outputStream.hasSpaceAvailable {
            let count = Swift.min(8192, payload.count - offset)
            let written = payload.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                let pointer = base.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
                return channel.outputStream.write(pointer, maxLength: count)
            }
            if written <= 0 { break }
            offset += written
            onProgress(Double(offset) / Double(payload.count))
        }
    }
}

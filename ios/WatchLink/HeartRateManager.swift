import AVFoundation
import UIKit
import AudioToolbox
import CoreBluetooth
import CryptoKit
import Foundation
import UserNotifications

/// Clés des réglages (partagées avec l'écran Réglages via @AppStorage).
enum SettingsKey {
    static let alertEnabled = "alertEnabled"
    static let alertLow = "alertLow"
    static let alertHigh = "alertHigh"
    static let alertVibrate = "alertVibrate"
    static let alertPhone = "alertPhone"
    static let autostart = "autostart"
    static let hrInterval = "hrInterval"
    static let heightCm = "heightCm"
    static let offWristNotify = "offWristNotify"
    static let mirrorNotifications = "mirrorNotifications"
    static let ageYears = "ageYears"
    static let weightKg = "weightKg"
    static let stepGoal = "stepGoal"
    static let stepGoalNotify = "stepGoalNotify"
    static let moveMinutes = "moveMinutes"
    static let quietEnabled = "quietEnabled"
    static let quietStart = "quietStart"
    static let quietEnd = "quietEnd"
    static let appMask = "appMask"
    static let batteryAlert = "batteryAlert"
    static let batteryAlertLevel = "batteryAlertLevel"
    static let disconnectAlert = "disconnectAlert"
}

/// État détaillé de la montre, envoyé à la demande.
struct WatchInfo {
    var temperature: Double   // °C, batterie
    var charging: Bool
    var freeMB: Int
    var uptimeHours: Int
    var sdk: Int
    var worn: Bool
    var brightness: Int
    var dnd: Bool
    var saver: Bool

    /// Version d'Android correspondant au niveau d'API.
    var androidVersion: String {
        switch sdk {
        case 36: return "Android 16"
        case 35: return "Android 15"
        case 34: return "Android 14"
        case 33: return "Android 13"
        default: return "API \(sdk)"
        }
    }
}

/// Ce que la montre est en train de faire pour qu'on la retrouve.
enum WatchAlert {
    case none, ring, vibrate
}

/// Client Bluetooth Low Energy : se connecte à la montre, qui joue le rôle de serveur.
///  - Heart Rate (0x180D) : battements par notification
///  - Battery (0x180F) : niveau de batterie
///  - service maison : commandes (sonnerie, vibration, seuils, intervalle de mesure)
///    et événements (pas du jour)
final class HeartRateManager: NSObject, ObservableObject {

    struct Found: Identifiable {
        let id: UUID
        let name: String
        let peripheral: CBPeripheral
    }

    @Published var bpm: Int?
    @Published var status = "Initialisation…"
    @Published var found: [Found] = []
    @Published var connectedName: String?
    @Published var battery: Int?
    @Published var steps: Int?
    @Published var watchAlert: WatchAlert = .none
    @Published var controlAvailable = false
    @Published var worn = true
    @Published var needsCode = false
    @Published var authenticated = false
    @Published var codeError: String?
    @Published var syncing = false
    @Published var watchInfo: WatchInfo?
    @Published var watchModel: String?
    @Published var watchVersion: String?
    @Published var fastChannel = false
    @Published var fastChannelError: String?
    @Published var screenImage: UIImage?
    /// 0 = arrêté, 1 = en cours, 2 = impossible (service d'accessibilité ou autorisation manquants)
    @Published var remoteState = 0
    /// Vrai quand les images passent par le canal rapide.
    @Published var fastChannel = false
    @Published var channelError: String?

    let history = HistoryStore()

    private static let hrService = CBUUID(string: "180D")
    private static let hrMeasurement = CBUUID(string: "2A37")
    private static let batteryService = CBUUID(string: "180F")
    private static let batteryLevel = CBUUID(string: "2A19")
    private static let controlService = CBUUID(string: "9F2B0001-6C1D-4A57-8E3B-5D6A7C8E9F10")
    private static let controlCommand = CBUUID(string: "9F2B0002-6C1D-4A57-8E3B-5D6A7C8E9F10")
    private static let controlEvent = CBUUID(string: "9F2B0003-6C1D-4A57-8E3B-5D6A7C8E9F10")
    private static let controlSync = CBUUID(string: "9F2B0004-6C1D-4A57-8E3B-5D6A7C8E9F10")
    private static let controlAuth = CBUUID(string: "9F2B0005-6C1D-4A57-8E3B-5D6A7C8E9F10")
    private static let savedKey = "savedPeripheralID"
    private static let pairKey = "pairingKey"

    private enum Attempt { case none, key, code }

    private var central: CBCentralManager!
    private var current: CBPeripheral?
    private var commandChar: CBCharacteristic?
    private var authChar: CBCharacteristic?
    private var syncChar: CBCharacteristic?
    private var hrChar: CBCharacteristic?
    private var batteryChar: CBCharacteristic?
    private var eventChar: CBCharacteristic?
    private var attempt: Attempt = .none
    private var pendingCode: String?
    private var usedCodeKey = Data()
    private var usedNonce = Data()
    private var syncCutoff = 0
    private var syncHeart: [(Int, Int)] = []
    private var syncBattery: [(Int, Int)] = []
    private var syncSteps: [(Int, Int)] = []
    private let finder = PhoneFinder()
    private var frameID = -1
    private var frameTotal = 0
    private var frameChunks: [Int: Data] = [:]
    private var l2cap: FrameChannel?
    private var l2capOpening = false
    private var remoteFormat = 1          // 1 = WebP, 0 = JPEG (repli si l'iPhone n'arrive pas à décoder le WebP)
    private var lastSide = 320
    private var lastQuality = 65
    private var decodeFailures = 0
    private var alertReset: DispatchWorkItem?
    private var lastPhoneAlert = Date.distantPast

    override init() {
        super.init()
        UserDefaults.standard.register(defaults: [
            SettingsKey.alertEnabled: false,
            SettingsKey.alertLow: 50,
            SettingsKey.alertHigh: 130,
            SettingsKey.alertVibrate: true,
            SettingsKey.alertPhone: true,
            SettingsKey.autostart: true,
            SettingsKey.hrInterval: 1,
            SettingsKey.heightCm: 175,
            SettingsKey.offWristNotify: true,
            SettingsKey.mirrorNotifications: false,
            SettingsKey.ageYears: 25,
            SettingsKey.weightKg: 70,
            SettingsKey.stepGoal: 8000,
            SettingsKey.stepGoalNotify: true,
            SettingsKey.moveMinutes: 0,
            SettingsKey.quietEnabled: false,
            SettingsKey.quietStart: 22,
            SettingsKey.quietEnd: 7,
            SettingsKey.appMask: 65535,
            SettingsKey.batteryAlert: true,
            SettingsKey.batteryAlertLevel: 15,
            SettingsKey.disconnectAlert: true
        ])
        UNUserNotificationCenter.current().delegate = self
        requestNotificationPermission()
        // La clé de restauration permet à iOS de relancer l'app en arrière-plan
        // quand la montre se reconnecte.
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "fr.nino.watchlink.central"]
        )
    }

    // MARK: - Connexion

    func startScan() {
        guard central.state == .poweredOn else { return }
        found.removeAll()
        status = "Recherche de la montre…"
        central.scanForPeripherals(
            withServices: [Self.hrService],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func connect(_ peripheral: CBPeripheral) {
        central.stopScan()
        current = peripheral
        peripheral.delegate = self
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.savedKey)
        status = "Connexion…"
        // connect() n'expire jamais : iOS se reconnectera dès que la montre est à portée
        central.connect(peripheral, options: nil)
    }

    func forget() {
        UserDefaults.standard.removeObject(forKey: Self.savedKey)
        UserDefaults.standard.removeObject(forKey: Self.pairKey)
        cancelDisconnectAlert()
        if let p = current { central.cancelPeripheralConnection(p) }
        current = nil
        resetLiveState()
        startScan()
    }

    private func reconnectSavedOrScan() {
        if let s = UserDefaults.standard.string(forKey: Self.savedKey),
           let uuid = UUID(uuidString: s),
           let p = central.retrievePeripherals(withIdentifiers: [uuid]).first {
            connect(p)
        } else {
            startScan()
        }
    }

    private func resetLiveState() {
        bpm = nil
        battery = nil
        connectedName = nil
        controlAvailable = false
        commandChar = nil
        authChar = nil
        syncChar = nil
        hrChar = nil
        batteryChar = nil
        eventChar = nil
        authenticated = false
        needsCode = false
        syncing = false
        watchInfo = nil
        screenImage = nil
        remoteState = 0
        closeFrameChannel()
        attempt = .none
        pendingCode = nil
        watchAlert = .none
        history.endSession()
    }

    // MARK: - Commandes vers la montre

    private func write(_ bytes: [UInt8]) {
        guard let p = current, let c = commandChar else { return }
        p.writeValue(Data(bytes), for: c, type: .withResponse)
    }

    /// Envoie les réglages à la montre (seuils, vibration, démarrage auto, intervalle de mesure).
    func sendConfig() {
        let d = UserDefaults.standard
        let enabled = d.bool(forKey: SettingsKey.alertEnabled)
        let low = enabled ? d.integer(forKey: SettingsKey.alertLow) : 0
        let high = enabled ? d.integer(forKey: SettingsKey.alertHigh) : 0
        let flags: UInt8 = d.bool(forKey: SettingsKey.alertVibrate) ? 1 : 0
        write([0x10, UInt8(clamping: low), UInt8(clamping: high), flags])
        write([0x30, d.bool(forKey: SettingsKey.autostart) ? 1 : 0])
        write([0x60, d.bool(forKey: SettingsKey.mirrorNotifications) ? 1 : 0])

        let move = UInt16(clamping: d.integer(forKey: SettingsKey.moveMinutes))
        write([0x70, UInt8(move >> 8), UInt8(move & 0xFF)])
        let mask = UInt16(clamping: d.integer(forKey: SettingsKey.appMask))
        write([0x71, UInt8(mask >> 8), UInt8(mask & 0xFF)])
        write([0x72,
               d.bool(forKey: SettingsKey.quietEnabled) ? 1 : 0,
               UInt8(clamping: d.integer(forKey: SettingsKey.quietStart)),
               UInt8(clamping: d.integer(forKey: SettingsKey.quietEnd))])

        let seconds = UInt16(clamping: d.integer(forKey: SettingsKey.hrInterval))
        write([0x40, UInt8(seconds >> 8), UInt8(seconds & 0xFF)])
    }

    // MARK: - Contrôle de la montre

    func requestInfo() { write([0x84]) }

    func setBrightness(_ level: Int, auto: Bool) {
        write([0x80, UInt8(clamping: level), auto ? 1 : 0])
    }

    func setScreenTimeout(_ seconds: Int) {
        let v = UInt16(clamping: seconds)
        write([0x81, UInt8(v >> 8), UInt8(v & 0xFF)])
    }

    func setDnd(_ on: Bool) { write([0x82, on ? 1 : 0]) }

    func setPowerSaver(_ on: Bool) { write([0x83, on ? 1 : 0]) }

    func startRing() {
        write([0x01])
        beginAlert(.ring)
    }

    func startVibrate() {
        write([0x03])
        beginAlert(.vibrate)
    }

    func stopAlert() {
        write([0x02])
        alertReset?.cancel()
        watchAlert = .none
    }

    private func beginAlert(_ kind: WatchAlert) {
        watchAlert = kind
        alertReset?.cancel()
        // La montre coupe seule au bout d'une minute
        let item = DispatchWorkItem { [weak self] in self?.watchAlert = .none }
        alertReset = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: item)
    }

    // MARK: - Liaison par code

    private var savedKey: Data? {
        guard let s = UserDefaults.standard.string(forKey: Self.pairKey) else { return nil }
        return Data(base64Encoded: s)
    }

    static func le32(_ b: [UInt8], at i: Int) -> Int {
        var n = 0
        for k in 0..<4 { n |= Int(b[i + k]) << (8 * k) }
        return n
    }

    private static func hmac16(_ key: Data, _ data: Data) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))
        return Data(mac.prefix(16))
    }

    /// Appelé quand la montre a envoyé son défi (nonce) : on le signe avec la clé ou avec le code saisi.
    private func handleAuth(_ b: [UInt8]) {
        guard let first = b.first else { return }
        switch first {
        case 0x10, 0x11:
            guard b.count >= 17 else { return }
            let nonce = Data(b[1..<17])
            usedNonce = nonce
            if let code = pendingCode {
                pendingCode = nil
                usedCodeKey = Data(SHA256.hash(data: Data(code.utf8)))
                attempt = .code
                write(auth: [0x02] + [UInt8](Self.hmac16(usedCodeKey, nonce)))
                status = "Vérification du code…"
            } else if let key = savedKey {
                attempt = .key
                write(auth: [0x01] + [UInt8](Self.hmac16(key, nonce)))
                status = "Authentification…"
            } else {
                attempt = .none
                needsCode = true
                status = "Sur la montre : Lier l'iPhone, puis saisis le code ici"
            }
        case 0x21:
            onAuthenticated()
        case 0x22:
            guard b.count >= 17 else { return }
            let stream = Self.hmac16(usedCodeKey, usedNonce + Data("enc".utf8))
            let key = Data(zip(b[1..<17], stream).map { $0 ^ $1 })
            UserDefaults.standard.set(key.base64EncodedString(), forKey: Self.pairKey)
            onAuthenticated()
        case 0x20:
            if attempt == .key {
                UserDefaults.standard.removeObject(forKey: Self.pairKey)
                codeError = "La montre ne reconnaît plus cet iPhone. Lance « Lier l'iPhone » sur la montre."
            } else {
                codeError = "Code incorrect ou expiré."
            }
            attempt = .none
            needsCode = true
            status = "Liaison refusée"
        default:
            break
        }
    }

    private func write(auth bytes: [UInt8]) {
        guard let p = current, let c = authChar else { return }
        p.writeValue(Data(bytes), for: c, type: .withResponse)
    }

    /// L'utilisateur a saisi le code affiché sur la montre.
    func submitCode(_ code: String) {
        guard let p = current, let c = authChar, code.count == 6 else { return }
        codeError = nil
        pendingCode = code
        // Nouveau défi à chaque essai
        p.readValue(for: c)
    }

    private func onAuthenticated() {
        cancelDisconnectAlert()
        authenticated = true
        needsCode = false
        codeError = nil
        attempt = .none
        controlAvailable = true
        status = "Connecté, attente des mesures…"
        guard let p = current else { return }
        if let c = hrChar { p.setNotifyValue(true, for: c) }
        if let c = batteryChar {
            p.readValue(for: c)
            p.setNotifyValue(true, for: c)
        }
        if let c = eventChar { p.setNotifyValue(true, for: c) }
        if let c = syncChar { p.setNotifyValue(true, for: c) }
        sendConfig()
        requestSync()
    }

    // MARK: - Synchronisation des mesures prises hors connexion

    private func requestSync() {
        syncCutoff = Int(Date().timeIntervalSince1970)
        let since = history.lastHeartRateTime ?? (syncCutoff - 7 * 24 * 3600)
        syncHeart.removeAll()
        syncBattery.removeAll()
        syncSteps.removeAll()
        syncing = true
        let s = UInt32(clamping: since)
        write([0x50, UInt8(s & 0xFF), UInt8((s >> 8) & 0xFF), UInt8((s >> 16) & 0xFF), UInt8((s >> 24) & 0xFF)])
    }

    private func handleSync(_ b: [UInt8]) {
        guard let type = b.first else { return }
        switch type {
        case 0x01:
            var i = 1
            while i + 5 <= b.count {
                syncHeart.append((Self.le32(b, at: i), Int(b[i + 4])))
                i += 5
            }
        case 0x02:
            var i = 1
            while i + 5 <= b.count {
                syncBattery.append((Self.le32(b, at: i), Int(b[i + 4])))
                i += 5
            }
        case 0x03:
            var i = 1
            while i + 8 <= b.count {
                syncSteps.append((Self.le32(b, at: i), Self.le32(b, at: i + 4)))
                i += 8
            }
        case 0x10:
            handleFrame(b)
        case 0xFF:
            let count = history.mergeSync(heart: syncHeart, battery: syncBattery,
                                          steps: syncSteps, cutoff: syncCutoff)
            syncing = false
            if count > 0 { status = "\(count) mesures récupérées depuis la montre" }
            syncHeart.removeAll()
            syncBattery.removeAll()
            syncSteps.removeAll()
        default:
            break
        }
    }

    // MARK: - Écran de la montre à distance

    /// Paquet d'image : [0x10, numéro d'image, numéro de paquet (2), nombre de paquets (2), données JPEG].
    private func handleFrame(_ b: [UInt8]) {
        guard b.count > 6 else { return }
        let id = Int(b[1])
        let index = Int(b[2]) << 8 | Int(b[3])
        let total = Int(b[4]) << 8 | Int(b[5])
        if id != frameID {
            frameID = id
            frameTotal = total
            frameChunks = [:]
        }
        frameChunks[index] = Data(b[6...])
        guard frameChunks.count == frameTotal else { return }
        var jpeg = Data()
        for i in 0..<frameTotal {
            guard let chunk = frameChunks[i] else { return }
            jpeg.append(chunk)
        }
        frameChunks = [:]
        showFrame(jpeg)
    }

    /// Affiche une image reçue (par le canal rapide ou par les notifications).
    private func showFrame(_ data: Data) {
        if let image = UIImage(data: data) {
            screenImage = image
            decodeFailures = 0
        } else {
            decodeFailures += 1
            // Si le WebP ne peut pas être lu, on repasse la montre en JPEG
            if decodeFailures >= 2 && remoteFormat == 1 {
                remoteFormat = 0
                decodeFailures = 0
                remoteStart(side: lastSide, quality: lastQuality)
            }
        }
    }

    private func closeFrameChannel() {
        l2cap?.close()
        l2cap = nil
        l2capOpening = false
        fastChannel = false
    }

    /// La montre annonce son canal rapide : on l'ouvre. Les images y arrivent bien plus vite que par notifications.
    private func openFrameChannel(psm: UInt16) {
        guard let p = current, l2cap == nil, !l2capOpening else { return }
        l2capOpening = true
        p.openL2CAPChannel(CBL2CAPPSM(psm))
    }

    func remoteStart(side: Int, quality: Int) {
        lastSide = side
        lastQuality = quality
        channelError = nil
        closeFrameChannel()
        write([0x90, 1, UInt8(clamping: side / 10), UInt8(clamping: quality), UInt8(remoteFormat)])
    }

    func remoteStop() {
        write([0x90, 0, 0, 0, 0])
        closeFrameChannel()
        remoteState = 0
    }

    private func fraction(_ v: Double) -> [UInt8] {
        let n = UInt16(Swift.max(0, Swift.min(1, v)) * 65535)
        return [UInt8(n >> 8), UInt8(n & 0xFF)]
    }

    func remoteTap(x: Double, y: Double) {
        var bytes: [UInt8] = [0x91]
        bytes += fraction(x)
        bytes += fraction(y)
        write(bytes)
    }

    func remoteSwipe(from a: (Double, Double), to b: (Double, Double), durationMs: Int) {
        let d = UInt16(clamping: durationMs)
        var bytes: [UInt8] = [0x92]
        bytes += fraction(a.0)
        bytes += fraction(a.1)
        bytes += fraction(b.0)
        bytes += fraction(b.1)
        bytes += [UInt8(d >> 8), UInt8(d & 0xFF)]
        write(bytes)
    }

    /// 0 = retour, 1 = accueil, 2 = applications récentes, 3 = notifications.
    func remoteNavigate(_ kind: UInt8) {
        write([0x93, kind])
    }

    // MARK: - Montre retirée

    private func setWorn(_ isWorn: Bool) {
        let wasWorn = worn
        worn = isWorn
        if isWorn {
            status = "Montre remise au poignet"
        } else {
            status = "Montre retirée : pas de mesure cardiaque"
            if wasWorn, UserDefaults.standard.bool(forKey: SettingsKey.offWristNotify) {
                let content = UNMutableNotificationContent()
                content.title = "Montre retirée"
                content.body = "Ta montre n'est plus au poignet. La mesure du rythme cardiaque est en pause."
                content.sound = .default
                UNUserNotificationCenter.current().add(
                    UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            }
        }
    }

    // MARK: - Alertes : batterie, connexion, objectif de pas

    private var batteryAlertSent = false

    private func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private func checkBatteryAlert(_ level: Int) {
        let d = UserDefaults.standard
        guard d.bool(forKey: SettingsKey.batteryAlert) else { return }
        let threshold = d.integer(forKey: SettingsKey.batteryAlertLevel)
        if level <= threshold {
            if !batteryAlertSent {
                batteryAlertSent = true
                notify("Batterie de la montre faible", "Il reste \(level) %.")
            }
        } else if level > threshold + 5 {
            batteryAlertSent = false
        }
    }

    private func checkStepGoal(_ n: Int) {
        let d = UserDefaults.standard
        guard d.bool(forKey: SettingsKey.stepGoalNotify) else { return }
        let goal = d.integer(forKey: SettingsKey.stepGoal)
        let today = HistoryStore.dayKey()
        guard goal > 0, n >= goal, d.string(forKey: "stepGoalDay") != today else { return }
        d.set(today, forKey: "stepGoalDay")
        notify("Objectif de pas atteint", "\(n) pas aujourd'hui, objectif de \(goal) atteint.")
    }

    /// Notification de déconnexion programmée 1 minute à l'avance : iOS la déclenche même si l'app est
    /// suspendue, et on l'annule si la montre revient avant.
    private func scheduleDisconnectAlert() {
        guard UserDefaults.standard.bool(forKey: SettingsKey.disconnectAlert) else { return }
        let content = UNMutableNotificationContent()
        content.title = "Montre déconnectée"
        content.body = "L'iPhone ne reçoit plus ta montre. Elle est peut-être hors de portée."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 60, repeats: false)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "disconnect-alert", content: content, trigger: trigger))
    }

    private func cancelDisconnectAlert() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["disconnect-alert"])
        center.removeDeliveredNotifications(withIdentifiers: ["disconnect-alert"])
    }

    // MARK: - Alertes sur l'iPhone

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func checkAlert(_ bpm: Int) {
        let d = UserDefaults.standard
        guard d.bool(forKey: SettingsKey.alertEnabled), d.bool(forKey: SettingsKey.alertPhone) else { return }
        let low = d.integer(forKey: SettingsKey.alertLow)
        let high = d.integer(forKey: SettingsKey.alertHigh)
        let tooLow = low > 0 && bpm < low
        let tooHigh = high > 0 && bpm > high
        // Une notification au maximum toutes les 2 minutes
        guard tooLow || tooHigh, Date().timeIntervalSince(lastPhoneAlert) > 120 else { return }
        lastPhoneAlert = Date()

        let content = UNMutableNotificationContent()
        content.title = "Rythme cardiaque"
        content.body = tooHigh ? "\(bpm) bpm : au-dessus de \(high)" : "\(bpm) bpm : en dessous de \(low)"
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension HeartRateManager: UNUserNotificationCenterDelegate {
    /// Affiche aussi la bannière quand l'app est ouverte.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if notification.request.identifier.hasPrefix("finder") {
            completionHandler([.banner])
        } else {
            completionHandler([.banner, .sound])
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension HeartRateManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if let p = current {
                // App relancée par iOS avec une connexion déjà active
                if p.state == .connected {
                    p.discoverServices([Self.hrService, Self.batteryService, Self.controlService])
                } else {
                    central.connect(p, options: nil)
                }
            } else {
                reconnectSavedOrScan()
            }
        case .poweredOff:
            status = "Bluetooth désactivé"
        case .unauthorized:
            status = "Autorise le Bluetooth pour WatchLink dans Réglages"
        default:
            status = "Bluetooth indisponible"
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let p = peripherals.first {
            current = p
            p.delegate = self
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name
            ?? "Appareil inconnu"
        if !found.contains(where: { $0.id == peripheral.identifier }) {
            found.append(Found(id: peripheral.identifier, name: name, peripheral: peripheral))
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectedName = peripheral.name ?? "Montre"
        status = "Connecté, attente des mesures…"
        peripheral.discoverServices([Self.hrService, Self.batteryService, Self.controlService])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        status = "Échec de connexion, nouvel essai…"
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        let wasConnected = authenticated
        resetLiveState()
        if wasConnected { scheduleDisconnectAlert() }
        // Si l'utilisateur a oublié la montre, on ne se reconnecte pas
        guard UserDefaults.standard.string(forKey: Self.savedKey) == peripheral.identifier.uuidString else { return }
        status = "Montre déconnectée, reconnexion automatique…"
        // On redemande la connexion : elle aboutira quand la montre réapparaîtra
        central.connect(peripheral, options: nil)
    }
}

// MARK: - CBPeripheralDelegate

extension HeartRateManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services, !services.isEmpty else {
            status = "Services introuvables : oublie la montre puis reconnecte-la"
            return
        }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        for c in service.characteristics ?? [] {
            switch c.uuid {
            case Self.hrMeasurement:
                hrChar = c
            case Self.batteryLevel:
                batteryChar = c
            case Self.controlCommand:
                commandChar = c
            case Self.controlEvent:
                eventChar = c
            case Self.controlSync:
                syncChar = c
            case Self.controlAuth:
                authChar = c
                // La montre répond à la liaison par notification : on s'abonne avant de lire le défi
                peripheral.setNotifyValue(true, for: c)
            default:
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        l2capOpening = false
        if let error {
            channelError = "Canal rapide refusé : \(error.localizedDescription)"
            return
        }
        guard let channel else { return }
        channelError = nil
        l2cap = FrameChannel(channel: channel,
                             onFrame: { [weak self] data in self?.showFrame(data) },
                             onClose: { [weak self] in
                                 self?.l2cap = nil
                                 self?.fastChannel = false
                             })
        fastChannel = true
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if characteristic.uuid == Self.controlAuth, characteristic.isNotifying {
            peripheral.readValue(for: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard let data = characteristic.value else { return }

        switch characteristic.uuid {
        case Self.controlAuth:
            handleAuth([UInt8](data))

        case Self.controlSync:
            handleSync([UInt8](data))

        case Self.batteryLevel:
            if let level = data.first {
                battery = Int(level)
                history.addBattery(Int(level))
                checkBatteryAlert(Int(level))
            }

        case Self.controlEvent:
            let bytes = [UInt8](data)
            guard let kind = bytes.first else { return }
            if kind == 0x01, bytes.count >= 5 {
                // Pas du jour sur 4 octets, petit-boutiste
                let n = Self.le32(bytes, at: 1)
                steps = n
                history.setSteps(n)
                checkStepGoal(n)
            } else if kind == 0x02, bytes.count >= 2 {
                setWorn(bytes[1] != 0)
            } else if kind == 0x03, bytes.count >= 2 {
                finder.handle(kind: Int(bytes[1]))
            } else if kind == 0x04, bytes.count >= 13 {
                watchInfo = WatchInfo(
                    temperature: Double(Int(bytes[1]) << 8 | Int(bytes[2])) / 10,
                    charging: bytes[3] != 0,
                    freeMB: Int(bytes[4]) << 8 | Int(bytes[5]),
                    uptimeHours: Int(bytes[6]) << 8 | Int(bytes[7]),
                    sdk: Int(bytes[8]),
                    worn: bytes[9] != 0,
                    brightness: Int(bytes[10]),
                    dnd: bytes[11] != 0,
                    saver: bytes[12] != 0)
            } else if kind == 0x08, bytes.count >= 3 {
                openFrameChannel(psm: UInt16(bytes[1]) << 8 | UInt16(bytes[2]))
            } else if kind == 0x07, bytes.count >= 2 {
                watchVersion = String(decoding: bytes[1...], as: UTF8.self)
            } else if kind == 0x06, bytes.count >= 2 {
                remoteState = Int(bytes[1])
                if bytes[1] == 0 { screenImage = nil }
            } else if kind == 0x05, bytes.count >= 2 {
                watchModel = String(decoding: bytes[1...], as: UTF8.self)
            }

        case Self.hrMeasurement:
            guard data.count >= 2 else { return }
            let flags = data[0]
            // Bit 0 des flags : 0 = BPM sur 8 bits, 1 = BPM sur 16 bits
            let value: Int
            if flags & 0x01 == 0 {
                value = Int(data[1])
            } else if data.count >= 3 {
                value = Int(data[1]) | (Int(data[2]) << 8)
            } else {
                return
            }
            bpm = value
            status = "Mesure en direct"
            history.add(bpm: value)
            checkAlert(value)

        default:
            break
        }
    }
}

// MARK: - Retrouver l'iPhone depuis la montre

/// Fait sonner ou vibrer l'iPhone quand la montre le demande.
/// Écran allumé : son et vibration en boucle. En arrière-plan, iOS suspend l'app :
/// on programme alors une série de notifications sonores qui se déclenchent seules.
final class PhoneFinder {
    private var timer: Timer?
    private var player: AVAudioPlayer?
    private static let prefix = "finder-"

    func handle(kind: Int) {
        switch kind {
        case 1: start(ring: true)
        case 2: start(ring: false)
        default: stop()
        }
    }

    private func start(ring: Bool) {
        stop()
        let center = UNUserNotificationCenter.current()
        for i in 0..<12 {
            let content = UNMutableNotificationContent()
            content.title = ring ? "Ta montre cherche ton iPhone" : "Ta montre te fait signe"
            content.body = "Ouvre WatchLink ou annule depuis la montre."
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: Double(i * 5 + 1), repeats: false)
            center.add(UNNotificationRequest(identifier: Self.prefix + "\(i)", content: content, trigger: trigger))
        }
        startAudio(loud: ring)
        var ticks = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] t in
            ticks += 1
            if ticks > 40 {
                self?.stop()
                return
            }
            if ring { AudioServicesPlaySystemSound(1005) }
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
    }

    /// Une session audio « lecture » garde l'app vivante écran éteint (mode audio en arrière-plan)
    /// et joue un bip en boucle, même en mode silencieux. Pour la vibration seule, le volume est à zéro.
    private func startAudio(loud: Bool) {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
            let p = try AVAudioPlayer(data: Self.beepWav())
            p.numberOfLoops = -1
            p.volume = loud ? 1.0 : 0.0
            p.play()
            player = p
        } catch {
            player = nil
        }
    }

    /// Bip de 880 Hz pendant 0,4 s puis silence de 0,4 s, au format WAV 16 bits mono.
    private static func beepWav() -> Data {
        let rate = 22050
        let count = rate * 8 / 10
        var samples = [Int16](repeating: 0, count: count)
        for i in 0..<(rate * 4 / 10) {
            samples[i] = Int16(sin(2 * Double.pi * 880 * Double(i) / Double(rate)) * 28000)
        }
        func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
        func le16(_ v: Int) -> [UInt8] { (0..<2).map { UInt8((v >> (8 * $0)) & 0xFF) } }
        var d = Data()
        d.append(contentsOf: Array("RIFF".utf8)); d.append(contentsOf: le32(36 + count * 2))
        d.append(contentsOf: Array("WAVEfmt ".utf8)); d.append(contentsOf: le32(16))
        d.append(contentsOf: le16(1)); d.append(contentsOf: le16(1))
        d.append(contentsOf: le32(rate)); d.append(contentsOf: le32(rate * 2))
        d.append(contentsOf: le16(2)); d.append(contentsOf: le16(16))
        d.append(contentsOf: Array("data".utf8)); d.append(contentsOf: le32(count * 2))
        for v in samples { d.append(contentsOf: le16(Int(UInt16(bitPattern: v)))) }
        return d
    }

    private func stop() {
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        timer?.invalidate()
        timer = nil
        let ids = (0..<12).map { Self.prefix + "\($0)" }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }
}

// MARK: - Canal rapide (L2CAP) pour les images de l'écran à distance

/// Lit les images envoyées par la montre : chaque image est précédée de sa taille sur 4 octets.
final class FrameChannel: NSObject, StreamDelegate {
    private let channel: CBL2CAPChannel
    private var buffer = Data()
    private let onFrame: (Data) -> Void
    private let onClose: () -> Void
    private var closed = false

    init(channel: CBL2CAPChannel, onFrame: @escaping (Data) -> Void, onClose: @escaping () -> Void) {
        self.channel = channel
        self.onFrame = onFrame
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
        case .hasBytesAvailable:
            readAvailable()
        case .endEncountered, .errorOccurred:
            close()
            onClose()
        default:
            break
        }
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 16384)
        while channel.inputStream.hasBytesAvailable {
            let n = channel.inputStream.read(&chunk, maxLength: chunk.count)
            if n <= 0 { break }
            buffer.append(chunk, count: n)
        }
        parse()
    }

    private func parse() {
        while buffer.count >= 4 {
            let s = buffer.startIndex
            let b0 = Int(buffer[s]) << 24
            let b1 = Int(buffer[s + 1]) << 16
            let b2 = Int(buffer[s + 2]) << 8
            let b3 = Int(buffer[s + 3])
            let length = b0 | b1 | b2 | b3
            if length <= 0 || length > 4_000_000 {
                close()
                onClose()
                return
            }
            guard buffer.count >= 4 + length else { return }
            let frame = buffer.subdata(in: (s + 4)..<(s + 4 + length))
            buffer.removeSubrange(s..<(s + 4 + length))
            onFrame(frame)
        }
    }
}

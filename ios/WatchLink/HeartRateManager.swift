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
            SettingsKey.offWristNotify: true
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

        let seconds = UInt16(clamping: d.integer(forKey: SettingsKey.hrInterval))
        write([0x40, UInt8(seconds >> 8), UInt8(seconds & 0xFF)])
    }

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
        resetLiveState()
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
            }

        case Self.controlEvent:
            let bytes = [UInt8](data)
            guard let kind = bytes.first else { return }
            if kind == 0x01, bytes.count >= 5 {
                // Pas du jour sur 4 octets, petit-boutiste
                let n = Self.le32(bytes, at: 1)
                steps = n
                history.setSteps(n)
            } else if kind == 0x02, bytes.count >= 2 {
                setWorn(bytes[1] != 0)
            } else if kind == 0x03, bytes.count >= 2 {
                finder.handle(kind: Int(bytes[1]))
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

    private func stop() {
        timer?.invalidate()
        timer = nil
        let ids = (0..<12).map { Self.prefix + "\($0)" }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }
}

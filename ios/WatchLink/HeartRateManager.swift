import CoreBluetooth
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

    let history = HistoryStore()

    private static let hrService = CBUUID(string: "180D")
    private static let hrMeasurement = CBUUID(string: "2A37")
    private static let batteryService = CBUUID(string: "180F")
    private static let batteryLevel = CBUUID(string: "2A19")
    private static let controlService = CBUUID(string: "9F2B0001-6C1D-4A57-8E3B-5D6A7C8E9F10")
    private static let controlCommand = CBUUID(string: "9F2B0002-6C1D-4A57-8E3B-5D6A7C8E9F10")
    private static let controlEvent = CBUUID(string: "9F2B0003-6C1D-4A57-8E3B-5D6A7C8E9F10")
    private static let savedKey = "savedPeripheralID"

    private var central: CBCentralManager!
    private var current: CBPeripheral?
    private var commandChar: CBCharacteristic?
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
            SettingsKey.heightCm: 175
        ])
        UNUserNotificationCenter.current().delegate = self
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
        completionHandler([.banner, .sound])
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
                peripheral.setNotifyValue(true, for: c)
            case Self.batteryLevel:
                peripheral.readValue(for: c)
                peripheral.setNotifyValue(true, for: c)
            case Self.controlCommand:
                commandChar = c
                controlAvailable = true
                sendConfig()
            case Self.controlEvent:
                peripheral.setNotifyValue(true, for: c)
            default:
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard let data = characteristic.value else { return }

        switch characteristic.uuid {
        case Self.batteryLevel:
            if let level = data.first {
                battery = Int(level)
                history.addBattery(Int(level))
            }

        case Self.controlEvent:
            // Événement 0x01 : pas du jour sur 4 octets, petit-boutiste
            if data.count >= 5, data[0] == 0x01 {
                var n = 0
                for i in 0..<4 {
                    n |= Int(data[data.startIndex + 1 + i]) << (8 * i)
                }
                steps = n
                history.setSteps(n)
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

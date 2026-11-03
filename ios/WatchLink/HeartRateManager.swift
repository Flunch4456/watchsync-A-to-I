import CoreBluetooth
import Foundation

/// Client Bluetooth Low Energy : se connecte à la montre (qui joue le rôle de serveur
/// "Heart Rate", service 0x180D) et reçoit les battements par notification.
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

    private static let heartRateService = CBUUID(string: "180D")
    private static let heartRateMeasurement = CBUUID(string: "2A37")
    private static let savedKey = "savedPeripheralID"

    private var central: CBCentralManager!
    private var current: CBPeripheral?

    override init() {
        super.init()
        // La clé de restauration permet à iOS de relancer l'app en arrière-plan
        // quand la montre se reconnecte.
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "fr.nino.watchlink.central"]
        )
    }

    // MARK: - Actions de l'interface

    func startScan() {
        guard central.state == .poweredOn else { return }
        found.removeAll()
        status = "Recherche de la montre…"
        central.scanForPeripherals(
            withServices: [Self.heartRateService],
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
        if let p = current { central.cancelPeripheralConnection(p) }
        current = nil
        connectedName = nil
        bpm = nil
        UserDefaults.standard.removeObject(forKey: Self.savedKey)
        startScan()
    }

    // MARK: - Reconnexion automatique

    private func reconnectSavedOrScan() {
        if let s = UserDefaults.standard.string(forKey: Self.savedKey),
           let uuid = UUID(uuidString: s),
           let p = central.retrievePeripherals(withIdentifiers: [uuid]).first {
            connect(p)
        } else {
            startScan()
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension HeartRateManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if current == nil { reconnectSavedOrScan() }
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
        peripheral.discoverServices([Self.heartRateService])
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
        bpm = nil
        connectedName = nil
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
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.heartRateService }) else {
            status = "Service cardiaque introuvable"
            return
        }
        peripheral.discoverCharacteristics([Self.heartRateMeasurement], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard let c = service.characteristics?.first(where: { $0.uuid == Self.heartRateMeasurement }) else { return }
        peripheral.setNotifyValue(true, for: c)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard let data = characteristic.value, data.count >= 2 else { return }
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
    }
}

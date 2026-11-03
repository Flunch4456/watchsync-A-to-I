import Foundation

/// Une mesure : `t` en secondes Unix, `b` en battements par minute ou en pourcentage (format compact pour le JSON).
struct Sample: Codable, Identifiable {
    let t: Int
    let b: Int
    var id: Int { t }
    var date: Date { Date(timeIntervalSince1970: TimeInterval(t)) }
}

struct Stats {
    let low: Int
    let avg: Int
    let high: Int

    init?(_ samples: [Sample]) {
        guard let first = samples.first else { return nil }
        var lo = first.b
        var hi = first.b
        var sum = 0
        for s in samples {
            lo = Swift.min(lo, s.b)
            hi = Swift.max(hi, s.b)
            sum += s.b
        }
        low = lo
        high = hi
        avg = sum / samples.count
    }
}

struct Session: Codable, Identifiable {
    let id: UUID
    let start: Int
    var samples: [Sample]

    var end: Int { samples.last?.t ?? start }
    var startDate: Date { Date(timeIntervalSince1970: TimeInterval(start)) }
    var duration: TimeInterval { TimeInterval(end - start) }
}

struct DaySteps: Identifiable {
    let date: Date
    let steps: Int
    var id: Date { date }
}

func formatDuration(_ seconds: TimeInterval) -> String {
    let total = Int(seconds)
    let h = total / 3600
    let m = (total % 3600) / 60
    if h > 0 { return "\(h) h \(m) min" }
    if m > 0 { return "\(m) min" }
    return "\(total) s"
}

/// Garde la courbe en direct (1 point par seconde, 2 minutes), l'historique des sessions
/// (1 point toutes les 10 secondes, 7 jours), les pas par jour et le journal de batterie.
/// Tout est enregistré dans des fichiers JSON du dossier Documents de l'app.
final class HistoryStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    @Published private(set) var live: [Sample] = []
    @Published private(set) var dailySteps: [String: Int] = [:]
    @Published private(set) var batteryLog: [Sample] = []

    private var currentID: UUID?
    private var lastStored = 0
    private var lastSave = Date.distantPast
    private let sessionsURL: URL
    private let stepsURL: URL
    private let batteryURL: URL
    private let retention: TimeInterval = 7 * 24 * 3600

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        sessionsURL = dir.appendingPathComponent("history.json")
        stepsURL = dir.appendingPathComponent("steps.json")
        batteryURL = dir.appendingPathComponent("battery.json")
        load()
    }

    private var currentIndex: Int? {
        guard let id = currentID else { return nil }
        return sessions.firstIndex(where: { $0.id == id })
    }

    /// Statistiques de la session en cours.
    var currentStats: Stats? {
        guard let i = currentIndex else { return nil }
        return Stats(sessions[i].samples)
    }

    // MARK: - Rythme cardiaque

    func add(bpm: Int) {
        let now = Date()
        let t = Int(now.timeIntervalSince1970)

        if live.last?.t != t {
            live.append(Sample(t: t, b: bpm))
            if live.count > 120 { live.removeFirst(live.count - 120) }
        }

        // Nouvelle session s'il n'y en a pas, ou après plus de 5 minutes sans mesure
        if let i = currentIndex, t - sessions[i].end > 300 {
            currentID = nil
        }
        if currentIndex == nil {
            let session = Session(id: UUID(), start: t, samples: [])
            sessions.append(session)
            currentID = session.id
            lastStored = 0
        }
        if let i = currentIndex, t - lastStored >= 10 {
            sessions[i].samples.append(Sample(t: t, b: bpm))
            lastStored = t
        }
        if now.timeIntervalSince(lastSave) > 60 { save() }
    }

    /// À appeler quand la montre se déconnecte.
    func endSession() {
        currentID = nil
        live.removeAll()
        save()
    }

    func delete(_ id: UUID) {
        if currentID == id { currentID = nil }
        sessions.removeAll { $0.id == id }
        save()
    }

    func clear() {
        currentID = nil
        sessions.removeAll()
        save()
    }

    // MARK: - Pas

    static func dayKey(_ date: Date = Date()) -> String {
        dayFormatter.string(from: date)
    }

    func setSteps(_ n: Int) {
        dailySteps[Self.dayKey()] = n
    }

    var todaySteps: Int {
        dailySteps[Self.dayKey()] ?? 0
    }

    /// Les pas des 7 derniers jours, du plus ancien au plus récent.
    func weekSteps() -> [DaySteps] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<7).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return DaySteps(date: day, steps: dailySteps[Self.dayKey(day)] ?? 0)
        }
    }

    // MARK: - Batterie de la montre

    func addBattery(_ level: Int) {
        let t = Int(Date().timeIntervalSince1970)
        // On ne note pas deux fois le même niveau à moins de 10 minutes d'écart
        if let last = batteryLog.last, last.b == level, t - last.t < 600 { return }
        batteryLog.append(Sample(t: t, b: level))
    }

    // MARK: - Mesures prises par la montre hors connexion

    /// Heure de la dernière mesure cardiaque connue (pour ne redemander que le nouveau).
    var lastHeartRateTime: Int? {
        sessions.compactMap { $0.samples.last?.t }.max()
    }

    private static let utcDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Ajoute ce que la montre a enregistré pendant la déconnexion. `cutoff` = instant de la reconnexion :
    /// au-delà, les mesures arrivent déjà en direct, on les ignore pour ne pas les compter deux fois.
    /// Renvoie le nombre de mesures cardiaques ajoutées.
    @discardableResult
    func mergeSync(heart: [(Int, Int)], battery: [(Int, Int)], steps: [(Int, Int)], cutoff: Int) -> Int {
        let known = Set(sessions.flatMap { $0.samples.map { $0.t } })
        let fresh = heart
            .filter { $0.0 < cutoff && $0.1 > 0 && !known.contains($0.0) }
            .sorted { $0.0 < $1.0 }

        var block: [Sample] = []
        func flush() {
            if let first = block.first {
                sessions.append(Session(id: UUID(), start: first.t, samples: block))
            }
            block = []
        }
        for (t, b) in fresh {
            if let last = block.last, t - last.t > 300 { flush() }
            block.append(Sample(t: t, b: b))
        }
        flush()
        sessions.sort { $0.start < $1.start }

        let knownBattery = Set(batteryLog.map { $0.t })
        for (t, level) in battery where t < cutoff && !knownBattery.contains(t) {
            batteryLog.append(Sample(t: t, b: level))
        }
        batteryLog.sort { $0.t < $1.t }

        for (epochDay, count) in steps {
            let day = Self.utcDayFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(epochDay) * 86400))
            dailySteps[day] = Swift.max(dailySteps[day] ?? 0, count)
        }
        save()
        return fresh.count
    }

    // MARK: - Fichiers

    func save() {
        lastSave = Date()
        prune()
        write(sessions, to: sessionsURL)
        write(dailySteps, to: stepsURL)
        write(batteryLog, to: batteryURL)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        // L'historique est un confort : on ne bloque pas l'app si l'écriture échoue
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func load() {
        if let stored = read([Session].self, from: sessionsURL) { sessions = stored }
        if let stored = read([String: Int].self, from: stepsURL) { dailySteps = stored }
        if let stored = read([Sample].self, from: batteryURL) { batteryLog = stored }
        prune()
    }

    private func prune() {
        let cutoff = Int(Date().timeIntervalSince1970 - retention)
        sessions.removeAll { $0.end < cutoff && $0.id != currentID }
        batteryLog.removeAll { $0.t < cutoff }
    }

    /// Écrit un fichier CSV temporaire à partager (Fichiers, Mail, tableur…).
    func exportCSV(_ list: [Session], name: String) -> URL? {
        let formatter = ISO8601DateFormatter()
        var text = "debut_session,horodatage,bpm\n"
        for session in list {
            let start = formatter.string(from: session.startDate)
            for s in session.samples {
                text += "\(start),\(formatter.string(from: s.date)),\(s.b)\n"
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).csv")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}

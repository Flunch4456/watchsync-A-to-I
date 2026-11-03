import Foundation

/// Une mesure : `t` en secondes Unix, `b` en battements par minute (format compact pour le JSON).
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

func formatDuration(_ seconds: TimeInterval) -> String {
    let total = Int(seconds)
    let h = total / 3600
    let m = (total % 3600) / 60
    if h > 0 { return "\(h) h \(m) min" }
    if m > 0 { return "\(m) min" }
    return "\(total) s"
}

/// Garde la courbe en direct (1 point par seconde, 2 minutes) et l'historique des sessions
/// (1 point toutes les 10 secondes, conservé 7 jours dans un fichier JSON).
final class HistoryStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    @Published private(set) var live: [Sample] = []

    private var currentID: UUID?
    private var lastStored = 0
    private var lastSave = Date.distantPast
    private let fileURL: URL
    private let retention: TimeInterval = 7 * 24 * 3600

    init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = dir.appendingPathComponent("history.json")
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

    func save() {
        lastSave = Date()
        prune()
        do {
            let data = try JSONEncoder().encode(sessions)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // L'historique est un confort : on ne bloque pas l'app si l'écriture échoue
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([Session].self, from: data) else { return }
        sessions = stored
        prune()
    }

    private func prune() {
        let cutoff = Int(Date().timeIntervalSince1970 - retention)
        sessions.removeAll { $0.end < cutoff && $0.id != currentID }
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

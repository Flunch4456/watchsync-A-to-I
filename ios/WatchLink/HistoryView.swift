import SwiftUI
import Charts

struct HistoryView: View {
    @ObservedObject var history: HistoryStore
    @State private var confirmClear = false
    @State private var allCSV: URL?

    var body: some View {
        NavigationStack {
            Group {
                if history.sessions.isEmpty {
                    Text("Aucune session enregistrée pour l'instant.")
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    List {
                        ForEach(history.sessions.reversed()) { session in
                            NavigationLink {
                                SessionDetailView(id: session.id, history: history)
                            } label: {
                                SessionRow(session: session)
                            }
                            .contextMenu {
                                Button("Supprimer", role: .destructive) {
                                    history.delete(session.id)
                                }
                            }
                        }
                        if let url = allCSV {
                            Section {
                                ShareLink(item: url) {
                                    Label("Tout exporter en CSV", systemImage: "square.and.arrow.up")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Historique")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Tout effacer", role: .destructive) {
                        confirmClear = true
                    }
                    .disabled(history.sessions.isEmpty)
                }
            }
            .confirmationDialog("Effacer tout l'historique ?",
                                isPresented: $confirmClear,
                                titleVisibility: .visible) {
                Button("Effacer", role: .destructive) { history.clear() }
            }
            .onAppear {
                allCSV = history.sessions.isEmpty
                    ? nil
                    : history.exportCSV(history.sessions, name: "rythme-cardiaque-tout")
            }
        }
    }
}

struct SessionRow: View {
    let session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.startDate.formatted(date: .abbreviated, time: .shortened))
                .font(.headline)
            HStack(spacing: 12) {
                Text(formatDuration(session.duration))
                if let stats = Stats(session.samples) {
                    Text("min \(stats.low) · moy \(stats.avg) · max \(stats.high)")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }
}

struct SessionDetailView: View {
    let id: UUID
    @ObservedObject var history: HistoryStore
    @State private var csvURL: URL?

    private var session: Session? {
        history.sessions.first(where: { $0.id == id })
    }

    var body: some View {
        ScrollView {
            if let session = session {
                VStack(alignment: .leading, spacing: 20) {
                    Text(session.startDate.formatted(date: .complete, time: .shortened))
                        .font(.headline)
                    Text("Durée : \(formatDuration(session.duration))")
                        .foregroundStyle(.secondary)

                    if let stats = Stats(session.samples) {
                        HStack {
                            statBox("Min", stats.low)
                            statBox("Moyenne", stats.avg)
                            statBox("Max", stats.high)
                        }
                    }

                    if session.samples.count > 1 {
                        Chart(session.samples) { s in
                            LineMark(
                                x: .value("Heure", s.date),
                                y: .value("BPM", s.b)
                            )
                            .foregroundStyle(.red)
                        }
                        .chartYScale(domain: yDomain(session.samples))
                        .frame(height: 220)
                    } else {
                        Text("Pas encore assez de mesures pour tracer une courbe.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if let url = csvURL {
                        ShareLink(item: url) {
                            Label("Exporter en CSV", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding()
            } else {
                Text("Session introuvable.")
                    .padding()
            }
        }
        .navigationTitle("Session")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let s = session {
                csvURL = history.exportCSV([s], name: "rythme-cardiaque-\(s.start)")
            }
        }
    }

    private func statBox(_ title: String, _ value: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.title2.bold())
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}

import SwiftUI

struct ContentView: View {
    @StateObject private var manager = HeartRateManager()

    var body: some View {
        VStack(spacing: 20) {
            Text("WatchLink")
                .font(.title2.bold())

            VStack(spacing: 4) {
                Text(manager.bpm.map { String($0) } ?? "--")
                    .font(.system(size: 96, weight: .bold, design: .rounded))
                Text("battements / minute")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text(manager.status)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let name = manager.connectedName {
                Label(name, systemImage: "applewatch")
                Button("Oublier cette montre", role: .destructive) {
                    manager.forget()
                }
            } else {
                List(manager.found) { item in
                    Button {
                        manager.connect(item.peripheral)
                    } label: {
                        Label(item.name, systemImage: "dot.radiowaves.left.and.right")
                    }
                }
                .frame(maxHeight: 240)

                Button("Relancer la recherche") {
                    manager.startScan()
                }
            }

            Spacer()
        }
        .padding()
    }
}

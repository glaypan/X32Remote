import SwiftUI
import X32RemoteCore

struct ShowsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var showNewCardAlert = false
    @State private var newCardName = ""

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                List {
                    if appModel.showCards.isEmpty {
                        emptyState
                    } else {
                        ForEach(appModel.showCards) { card in
                            showCardRow(card)
                        }
                        .onDelete { indices in
                            for i in indices { appModel.deleteShowCard(appModel.showCards[i]) }
                        }
                    }
                }

                if appModel.isExecutingShow {
                    progressBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .navigationTitle("Shows")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        newCardName = ""
                        showNewCardAlert = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .alert("New Show", isPresented: $showNewCardAlert) {
                TextField("Show name", text: $newCardName)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    let name = newCardName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    appModel.addShowCard(name: name)
                }
            } message: {
                Text("Enter a name for the new show")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray").font(.system(size: 40)).foregroundColor(.secondary)
            Text("No shows")
                .font(.headline).foregroundColor(.secondary)
            Text("Tap + to create your first show")
                .font(.caption).foregroundColor(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func showCardRow(_ card: ShowCard) -> some View {
        NavigationLink(destination: ShowDetailView(card: card)) {
            HStack {
                circleIcon(card)

                VStack(alignment: .leading, spacing: 2) {
                    Text(card.name)
                        .font(.headline)
                    if let desc = card.description, !desc.isEmpty {
                        Text(desc)
                            .font(.caption).foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    HStack(spacing: 4) {
                        Label("\(card.actions.count)", systemImage: "list.bullet")
                            .font(.caption2).foregroundColor(.tertiary)
                        if !card.fades.isEmpty {
                            Label("\(card.fades.count)", systemImage: "slider.horizontal.below.square.filled.and.square")
                                .font(.caption2).foregroundColor(.tertiary)
                        }
                    }
                }

                Spacer()

                ExecuteButton(card: card)
            }
        }
    }

    private func circleIcon(_ card: ShowCard) -> some View {
        ZStack {
            Circle()
                .fill(Color(hex: card.color ?? "007AFF").opacity(0.15))
                .frame(width: 36, height: 36)
            Image(systemName: "play.fill")
                .font(.caption)
                .foregroundColor(Color(hex: card.color ?? "007AFF"))
        }
    }

    private var progressBar: some View {
        VStack(spacing: 4) {
            HStack {
                Image(systemName: "play.circle.fill")
                    .font(.caption).foregroundColor(.green)
                Text("Executing...")
                    .font(.caption).fontWeight(.medium)
                Spacer()
                Text("\(Int(appModel.showProgress * 100))%")
                    .font(.caption2.monospacedDigit()).foregroundColor(.secondary)
            }
            .padding(.horizontal)

            ProgressView(value: appModel.showProgress)
                .tint(.green)
                .padding(.horizontal)
        }
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Execute Button

private struct ExecuteButton: View {
    @Environment(AppModel.self) private var appModel
    let card: ShowCard

    var body: some View {
        Button {
            Task { await appModel.executeShowCard(card) }
        } label: {
            Label("Run", systemImage: "play.fill")
                .font(.caption.bold())
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(appModel.isExecutingShow ? Color.gray.opacity(0.2) : Color.green.opacity(0.15))
                .foregroundColor(appModel.isExecutingShow ? .gray : .green)
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .disabled(appModel.isExecutingShow)
    }
}

// MARK: - Hex Color Helper

private extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let scanner = Scanner(string: hex)
        var int: UInt64 = 0
        scanner.scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 6:
            (a, r, g, b) = (255, (int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = ((int >> 24) & 0xFF, (int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }
}

#Preview {
    ShowsView()
        .environment(AppModel())
}
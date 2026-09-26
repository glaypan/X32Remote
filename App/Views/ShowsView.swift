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
                    if !appModel.bridgeEvents.isEmpty {
                        eventSection
                    }
                    if appModel.showCards.isEmpty {
                        emptyState
                    } else {
                        ForEach(appModel.showCards) { card in
                            showCardRow(card)
                        }
                        .onDelete { indices in
                            let victims = indices.map { appModel.showCards[$0] }
                            Task { @MainActor in
                                for card in victims { appModel.deleteShowCard(card) }
                            }
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
                    Task { @MainActor in appModel.addShowCard(name: name) }
                }
            } message: {
                Text("Enter a name for the new show")
            }
        }
    }

    // MARK: - 桥接事件（真台手动干预 / 链路告警）

    private var eventSection: some View {
        Section {
            ForEach(Array(appModel.bridgeEvents.prefix(3))) { event in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: event.isWarning ? "exclamationmark.triangle.fill" : "info.circle")
                        .font(.caption)
                        .foregroundColor(event.isWarning ? Color.orange : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.text)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(event.time)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        } header: {
            HStack {
                Text("最近事件")
                Spacer()
                Button("清空") { appModel.bridgeEvents.removeAll() }
                    .font(.caption2)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray").font(.system(size: 40)).foregroundColor(.secondary)
            Text("No shows")
                .font(.headline).foregroundColor(.secondary)
            Text("Tap + to create your first show")
                .font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    // MARK: - 卡片行

    private func showCardRow(_ card: TimelineCard) -> some View {
        NavigationLink(destination: ShowDetailView(card: card)) {
            HStack {
                circleIcon(card)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        if card.pinned {
                            Image(systemName: "pin.fill")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }
                        Text(card.name)
                            .font(.headline)
                    }
                    if !card.desc.isEmpty {
                        Text(card.desc)
                            .font(.caption).foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    timelineSummary(card)
                }

                Spacer()

                ExecuteButton(card: card)
            }
        }
    }

    /// 卡片的时间轴概览：动作数 · 总时长 · 并行标记 · 接续
    private func timelineSummary(_ card: TimelineCard) -> some View {
        HStack(spacing: 8) {
            Label("\(card.actions.count)", systemImage: "list.bullet")
            Label(String(format: "%.1fs", card.totalSeconds), systemImage: "clock")
            if card.hasParallelActions {
                Label("并行", systemImage: "arrow.triangle.branch")
            }
            if let next = card.next, !next.isEmpty {
                Label(nextCardName(next), systemImage: "arrow.right.circle")
            }
        }
        .font(.caption2)
        .foregroundColor(.secondary)
        .lineLimit(1)
    }

    private func nextCardName(_ id: String) -> String {
        appModel.showCards.first(where: { $0.id == id })?.name ?? "接续"
    }

    private func circleIcon(_ card: TimelineCard) -> some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.15))
                .frame(width: 36, height: 36)
            Image(systemName: "play.fill")
                .font(.caption)
                .foregroundColor(Color.accentColor)
        }
    }

    // MARK: - 执行进度

    private var progressBar: some View {
        VStack(spacing: 4) {
            HStack {
                Image(systemName: "play.circle.fill")
                    .font(.caption).foregroundColor(.green)
                Text(appModel.cardProgress.name.isEmpty ? "执行中…" : appModel.cardProgress.name)
                    .font(.caption).fontWeight(.medium)
                    .lineLimit(1)
                Spacer()
                Text("\(Int(appModel.cardProgress.progress * 100))%")
                    .font(.caption2.monospacedDigit()).foregroundColor(.secondary)
                Button("停止") { Task { @MainActor in appModel.stopShow() } }
                    .font(.caption2)
                    .padding(.leading, 6)
            }
            .padding(.horizontal)

            ProgressView(value: Double(appModel.cardProgress.progress))
                .tint(.green)
                .padding(.horizontal)

            if !appModel.cardProgress.step.isEmpty {
                Text(appModel.cardProgress.step)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Execute Button

private struct ExecuteButton: View {
    @Environment(AppModel.self) private var appModel
    let card: TimelineCard

    var body: some View {
        Button {
            Task { @MainActor in appModel.runShowCard(card) }
        } label: {
            Label("Run", systemImage: "play.fill")
                .font(.caption.bold())
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(appModel.isExecutingShow ? Color.gray.opacity(0.2) : Color.green.opacity(0.15))
                .foregroundColor(appModel.isExecutingShow ? Color.gray : Color.green)
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ShowsView()
        .environment(AppModel())
}

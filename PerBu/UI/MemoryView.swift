import SwiftUI

/// What the app remembers, and a way to take it back.
///
/// A memory you cannot inspect is a memory you cannot trust — so every node is
/// listed with what it is, how often it came up, and what it is connected to.
struct MemoryView: View {
    @Environment(AppModel.self) private var model

    @State private var nodes: [MemoryNode] = []
    @State private var counts: (nodes: Int, edges: Int) = (0, 0)
    @State private var expanded: UUID?
    @State private var edgesOf: [UUID: [String]] = [:]
    @State private var search = ""
    @State private var confirmClear = false

    private var shown: [MemoryNode] {
        guard !search.isEmpty else { return nodes }
        return nodes.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || $0.type.localizedCaseInsensitiveContains(search)
                || $0.nodeDescription.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
            ZStack {
                EH.scene
                if nodes.isEmpty {
                    VStack(spacing: 16) {
                        Image("BrandMark")
                            .resizable().renderingMode(.template).aspectRatio(contentMode: .fit)
                            .frame(width: 44).foregroundStyle(EH.navy.opacity(0.5))
                        BrandRule()
                        EH.label("noch nichts gemerkt")
                        Text(model.settings.memory.isReady
                             ? "Nach ein paar Gesprächen steht hier, was PerBu über dich weiß."
                             : "Richte unter Einstellungen › Gedächtnis einen Einbettungs-Endpoint ein.")
                            .font(EH.bodySmall).foregroundStyle(EH.slate)
                            .multilineTextAlignment(.center).padding(.horizontal, 40)
                    }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(shown) { node in
                                nodeRow(node)
                            }
                        }
                        .padding(EH.gutter)
                    }
                    .searchable(text: $search, prompt: "Im Gedächtnis suchen")
                }
            }
            .navigationTitle(counts.nodes == 0 ? "Gedächtnis"
                             : "\(counts.nodes) Dinge · \(counts.edges) Verbindungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .destructiveAction) {
                    if !nodes.isEmpty {
                        Button("Alles vergessen", role: .destructive) { confirmClear = true }
                            .font(.eh(14, .footnote)).foregroundStyle(EH.bad)
                    }
                }
            }
            .alert("Alles vergessen?", isPresented: $confirmClear) {
                Button("Vergessen", role: .destructive) {
                    Task {
                        await MemoryStore.shared.forgetAll()
                        await reload()
                    }
                }
                Button("Behalten", role: .cancel) {}
            } message: {
                Text("Der gesamte Wissensgraph wird gelöscht. Die Unterhaltungen selbst bleiben.")
            }
        .task { await reload() }
    }

    private func nodeRow(_ node: MemoryNode) -> some View {
        HairlineCard(padding: 13, fill: expanded == node.id ? EH.surfaceSunk : EH.surface) {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) {
                        expanded = expanded == node.id ? nil : node.id
                    }
                    Task { await loadEdges(node.id) }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(node.name).font(EH.body).foregroundStyle(EH.navy)
                            HStack(spacing: 6) {
                                Text(node.type)
                                if node.mentions > 1 { Text("· \(node.mentions)× erwähnt") }
                            }
                            .font(.eh(11, .caption)).foregroundStyle(EH.muted)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: expanded == node.id ? "chevron.down" : "chevron.right")
                            .font(.eh(9, .caption2, weight: .medium)).foregroundStyle(EH.muted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(EHTap())

                if expanded == node.id {
                    if !node.nodeDescription.isEmpty {
                        Text(node.nodeDescription)
                            .font(.eh(12.5, .caption)).foregroundStyle(EH.slate)
                    }
                    if let lines = edgesOf[node.id], !lines.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(lines, id: \.self) { line in
                                Text("· " + line)
                                    .font(.eh(12, .caption)).foregroundStyle(EH.muted)
                            }
                        }
                    }
                    Button("Diesen Eintrag vergessen", role: .destructive) {
                        Task {
                            await MemoryStore.shared.forget(nodeID: node.id)
                            await reload()
                        }
                    }
                    .font(.eh(12, .caption)).foregroundStyle(EH.bad)
                    .padding(.top, 2)
                }
            }
        }
    }

    private func reload() async {
        await MemoryStore.shared.load()
        nodes = await MemoryStore.shared.allNodes()
        counts = await MemoryStore.shared.counts
    }

    private func loadEdges(_ id: UUID) async {
        guard edgesOf[id] == nil else { return }
        let edges = await MemoryStore.shared.edges(touching: id)
        var lines: [String] = []
        for e in edges {
            let otherID = e.sourceID == id ? e.targetID : e.sourceID
            guard let other = await MemoryStore.shared.node(otherID) else { continue }
            let arrow = e.sourceID == id ? "→" : "←"
            lines.append("\(e.relationship.replacingOccurrences(of: "_", with: " ")) \(arrow) \(other.name)")
        }
        edgesOf[id] = lines
    }
}

import ClippyCore
import SwiftUI

/// The panel: search field, list, preview, footer, key hints.
///
/// There is no real text field. Every keystroke is routed through the
/// controller's event monitor and appended to `model.query`, which is rendered
/// as text here. A non-activating panel makes SwiftUI focus unreliable — this
/// sidesteps it entirely and keeps the panel's keyboard behaviour deterministic.
struct PanelView: View {

    @ObservedObject var model: PanelModel
    @State private var hovered: Int?

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()

            if model.rows.isEmpty {
                empty
            } else {
                list
                Divider()
                preview
            }

            Divider()
            footer
        }
        .frame(width: 640, height: 460)
        .background(.regularMaterial)
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            if model.query.isEmpty {
                Text("Search clipboard history")
                    .foregroundStyle(.tertiary)
            } else {
                Text(model.query)
            }
            Spacer()
        }
        .font(.system(size: 15))
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var empty: some View {
        VStack {
            Spacer()
            Text(model.query.isEmpty ? "Nothing copied yet." : "No matches.")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - List

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                        rowView(index: index, row: row)
                            .id(row.id)
                    }
                }
            }
            .frame(height: 240)
            .onChange(of: model.selection) { _, new in
                guard model.rows.indices.contains(new) else { return }
                proxy.scrollTo(model.rows[new].id, anchor: .center)
            }
        }
    }

    private func rowView(index: Int, row: PanelRow) -> some View {
        let selected = index == model.selection

        return HStack(spacing: 10) {
            // Position numbers for the first nine — 1–9 pastes immediately, and
            // most uses are "the thing I copied two clips ago".
            Text(index < 9 ? "\(index + 1)" : " ")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(selected ? .white.opacity(0.8) : .secondary)
                .frame(width: 12)

            if row.isRedacted {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(selected ? .white : .secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(row.preview)
                    .lineLimit(1)
                    .foregroundStyle(selected ? .white : .primary)
                Text(row.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? .white.opacity(0.75) : .secondary)
            }

            Spacer()

            if let badge = row.badge {
                Text(badge)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(selected
                            ? Color.white.opacity(0.25)
                            : Color.secondary.opacity(0.18))
                    )
                    .foregroundStyle(selected ? .white : .secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(rowBackground(selected: selected, index: index))
        .contentShape(Rectangle())
        // Double-click pastes, single click only selects. Ordering matters:
        // SwiftUI matches the count:2 gesture first, and a single tap falls
        // through to the one below.
        .onTapGesture(count: 2) { model.activate(index) }
        .onTapGesture { model.select(index) }
        .onHover { inside in
            hovered = inside ? index : (hovered == index ? nil : hovered)
        }
    }

    private func rowBackground(selected: Bool, index: Int) -> Color {
        if selected { return .accentColor }
        if hovered == index { return .secondary.opacity(0.15) }
        return .clear
    }

    // MARK: - Preview

    private var preview: some View {
        ScrollView {
            HStack {
                Group {
                    if let item = model.selectedItem {
                        previewContent(item)
                    } else {
                        Text("")
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(14)
        }
        .frame(height: 110)
    }

    @ViewBuilder
    private func previewContent(_ item: ClipItem) -> some View {
        if item.retention.shouldRedact {
            Label("Concealed — held in memory only", systemImage: "lock.fill")
                .foregroundStyle(.secondary)
        } else if case .image(let data, _) = item.payload, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 90)
        } else {
            // Multi-line text keeps its structure here, unlike the one-line row.
            Text(item.payload.plainText ?? "")
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.message ?? model.footer)
                    .font(.system(size: 11))
                    .foregroundStyle(model.message == nil ? .secondary : .primary)
                    .lineLimit(2)
                Spacer()
                if model.truncatedCount > 0 {
                    Text("+\(model.truncatedCount) more — keep typing")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)

            Divider()

            HStack(spacing: 14) {
                hint("↑↓", "select")
                hint("1–9", "paste nth")
                hint("⏎", "paste")
                hint("⌥⏎", "raw")
                hint("⌘⌫", "delete")
                hint("esc", "close")
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

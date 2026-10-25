import AppKit
import SwiftUI

/// Curated symbol names for the icon picker. There is no public API to list
/// every SF Symbol, so this is a broad, readable set; names unavailable on the
/// running macOS are filtered out before they are shown.
enum DropzoneSymbolCatalog {
    static let curated: [String] = [
        "bolt.fill", "bolt.circle.fill", "wand.and.stars", "sparkles", "star.fill",
        "heart.fill", "flag.fill", "bookmark.fill", "tag.fill", "link",
        "paperclip", "folder.fill", "folder.badge.plus", "doc.fill", "doc.text.fill",
        "doc.on.doc.fill", "photo", "photo.on.rectangle", "camera.fill", "film.fill",
        "music.note", "waveform", "mic.fill", "speaker.wave.2.fill", "play.fill",
        "pause.fill", "stop.fill", "backward.fill", "forward.fill", "arrow.down.circle.fill",
        "arrow.up.circle.fill", "arrow.clockwise", "arrow.triangle.2.circlepath",
        "square.and.arrow.down", "square.and.arrow.up", "tray.and.arrow.down.fill",
        "tray.and.arrow.up.fill", "trash.fill", "archivebox.fill", "printer.fill",
        "magnifyingglass", "scissors", "paintbrush.fill", "hammer.fill",
        "wrench.and.screwdriver.fill", "desktopcomputer", "laptopcomputer", "display",
        "iphone", "ipad", "applewatch", "keyboard", "computermouse.fill", "externaldrive.fill",
        "server.rack", "network", "envelope.fill", "paperplane.fill", "bubble.left.fill",
        "message.fill", "phone.fill", "video.fill", "person.fill", "person.2.fill",
        "at", "globe", "terminal.fill", "chevron.left.forwardslash.chevron.right",
        "curlybraces", "curlybraces.square.fill", "number", "textformat", "list.bullet",
        "checklist", "calendar", "clock.fill", "bell.fill", "gearshape.fill",
        "shield.fill", "lock.fill", "key.fill", "eye.fill", "hand.raised.fill",
        "location.fill", "map.fill", "house.fill", "cart.fill", "creditcard.fill",
        "dollarsign.circle.fill", "shippingbox.fill", "airplane", "car.fill", "bicycle",
        "figure.walk", "pawprint.fill", "leaf.fill", "flame.fill", "drop.fill",
        "sun.max.fill", "moon.fill", "cloud.fill", "snowflake", "tornado",
        "rainbow", "cube.fill", "square.stack.3d.up.fill", "circle.grid.2x2.fill",
        "rectangle.3.group.fill", "arrow.up.left.and.arrow.down.right", "point.3.connected.trianglepath.dotted"
    ]

    /// Filters out names this macOS does not know, so the list never offers a
    /// symbol that renders as a question mark in the shelf.
    static let available: [String] = {
        var seen = Set<String>()
        return curated.filter {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil
                && seen.insert($0).inserted
        }
    }()
}

/// Common emoji. Not exhaustive; the detail view keeps a free text field for
/// anything else.
enum DropzoneEmojiCatalog {
    static let all: [String] = [
        "⚡️", "✨", "🔥", "💡", "🚀", "🧰", "🔧", "🪄", "📦", "🗂️",
        "📁", "📄", "📝", "🖼️", "🎨", "🎬", "🎵", "🎧", "📷", "📸",
        "🖥️", "💻", "⌨️", "🖱️", "🖨️", "💾", "🗑️", "📤", "📥", "🔗",
        "📎", "✂️", "📋", "📌", "🔍", "🧠", "🤖", "🦾", "🐢", "🐇",
        "🌍", "🌙", "☀️", "🌈", "❤️", "⭐️", "✅", "❌", "⚠️", "🔒",
        "🔑", "🛡️", "🧪", "🧬", "🧹", "🪣", "🧲", "🎯", "🏷️", "💬",
        "📣", "📞", "✉️", "📅", "⏰", "⏱️", "💰", "🛒", "🚚", "🏠",
        "☕️", "🍎", "🌱", "🍀", "🎉", "🏆", "🎁", "🧩", "🧭", "🗺️",
        "✈️", "🚗", "🚲", "🐾", "👀", "👍", "👎", "🙌", "👋", "🫶",
        "🧑‍💻", "🦊", "🐱", "🐶"
    ]
}

/// A searchable list of SF Symbols, each row rendering the actual symbol.
struct DropzoneSymbolPickerView: View {
    @Environment(\.paletteTheme) private var theme

    let selected: String?
    let onPick: (String) -> Void

    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SF Symbol")
                .font(.headline)
                .foregroundStyle(theme.text)
            Text("Pick a symbol; the field in the editor still accepts a custom name.")
                .font(.caption)
                .foregroundStyle(theme.subtext)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Search symbols", text: $query)
                .textFieldStyle(.roundedBorder)

            if filtered.isEmpty {
                Text("No symbol matches.")
                    .font(.caption)
                    .foregroundStyle(theme.subtext)
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filtered, id: \.self) { name in
                            Button {
                                onPick(name)
                            } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: name)
                                        .font(.system(size: 15))
                                        .frame(width: 22)
                                        .foregroundStyle(theme.text)
                                    Text(name)
                                        .font(.system(size: 11))
                                        .foregroundStyle(theme.text)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 4)
                                    if selected == name {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(theme.accent)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 5)
                                    .fill(selected == name
                                          ? theme.surfaceSelected
                                          : theme.surface.opacity(0.35)))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(name)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Text("\(filtered.count) symbols")
                .font(.caption2)
                .foregroundStyle(theme.subtext)
        }
        .padding(14)
        .frame(width: 360, height: 440)
        .background(theme.background)
        .environment(\.paletteTheme, theme)
    }

    private var symbols: [String] {
        let base = DropzoneSymbolCatalog.available
        if let selected, base.contains(selected) == false {
            return [selected] + base
        }
        return base
    }

    private var filtered: [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return symbols }
        return symbols.filter { $0.localizedCaseInsensitiveContains(trimmed) }
    }
}

/// A grid of common emoji, each rendered at the size used in the shelf tile.
struct DropzoneEmojiPickerView: View {
    @Environment(\.paletteTheme) private var theme

    let selected: String?
    let onPick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Emoji")
                .font(.headline)
                .foregroundStyle(theme.text)
            Text("Pick one; the field in the editor accepts any other emoji.")
                .font(.caption)
                .foregroundStyle(theme.subtext)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 5), count: 8),
                          spacing: 5) {
                    ForEach(emojis, id: \.self) { value in
                        Button {
                            onPick(value)
                        } label: {
                            Text(value)
                                .font(.system(size: 21))
                                .frame(width: 30, height: 30)
                                .background(RoundedRectangle(cornerRadius: 6)
                                    .fill(selected == value
                                          ? theme.surfaceSelected
                                          : Color.clear))
                                .overlay(RoundedRectangle(cornerRadius: 6)
                                    .stroke(selected == value ? theme.accent : Color.clear,
                                            lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .help(value)
                    }
                }
                .padding(2)
            }

            Text("The tile shows the emoji at up to 64 pt.")
                .font(.caption2)
                .foregroundStyle(theme.subtext)
        }
        .padding(14)
        .frame(width: 320, height: 400)
        .background(theme.background)
        .environment(\.paletteTheme, theme)
    }

    private var emojis: [String] {
        let base = DropzoneEmojiCatalog.all
        if let selected, base.contains(selected) == false {
            return [selected] + base
        }
        return base
    }
}

import GrizzyBotCore
import SwiftUI

struct ThemesSettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(ThemeManager.self) private var themeManager
    @State private var search = ""
    @State private var filter: ThemeGalleryFilter = .all

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Customize the look and feel of your chat interface.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)

            HStack(spacing: 8) {
                ForEach(ThemeGalleryFilter.allCases) { item in
                    filterChip(item, count: count(for: item))
                }
                Spacer(minLength: 8)
                searchField
            }

            if let active = activePreset {
                activeBanner(active)
            }

            HStack(spacing: 8) {
                Text(sectionTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textBright)
                Text("\(filteredPresets.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Theme.bgChip))
            }

            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 240, maximum: 300), spacing: 14)],
                    spacing: 14
                ) {
                    ForEach(filteredPresets) { preset in
                        themeCard(preset)
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
            TextField("Search themes", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textBright)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 200)
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Theme.borderInputsDark, lineWidth: 1)
        }
    }

    private var sectionTitle: String {
        switch filter {
        case .all: return search.isEmpty ? "Built-in Themes" : "Search Results"
        case .builtIn: return "Built-in Themes"
        case .grizzy: return "Grizzy Themes"
        }
    }

    private var activePreset: ThemePreset? {
        if themeManager.appearanceMode == .system {
            return ThemePresets.system
        }
        return ThemePresets.preset(id: themeManager.activePresetId)
            ?? ThemePresets.builtIn.first { $0.id == themeManager.activePresetId }
    }

    private func count(for item: ThemeGalleryFilter) -> Int {
        ThemePresets.builtIn.filter { preset in
            switch item {
            case .all: return true
            case .builtIn: return preset.id != ThemePresets.grizzy.id
            case .grizzy: return preset.id == ThemePresets.grizzy.id
            }
        }.count
    }

    private func filterChip(_ item: ThemeGalleryFilter, count: Int) -> some View {
        Button {
            filter = item
        } label: {
            HStack(spacing: 4) {
                Text(item.title)
                Text("(\(count))")
                    .foregroundStyle(filter == item ? Theme.textSecondary : Theme.textMuted)
            }
            .font(.system(size: 12, weight: filter == item ? .semibold : .regular))
            .foregroundStyle(filter == item ? Theme.textBright : Theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(filter == item ? Theme.bgSelectedRow : Theme.bgChip)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var filteredPresets: [ThemePreset] {
        ThemePresets.builtIn.filter { preset in
            switch filter {
            case .all: break
            case .builtIn:
                if preset.id == ThemePresets.grizzy.id { return false }
            case .grizzy:
                if preset.id != ThemePresets.grizzy.id { return false }
            }
            let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else { return true }
            let hay = "\(preset.name) \(preset.author)".lowercased()
            return hay.contains(q.lowercased())
        }
    }

    private func isActive(_ preset: ThemePreset) -> Bool {
        if preset.isSystem {
            return themeManager.appearanceMode == .system
        }
        return themeManager.activePresetId == preset.id
    }

    private func activeBanner(_ preset: ThemePreset) -> some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.green)
                Text("Currently Active")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textBright)
                Text(preset.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Theme.green.opacity(0.15)))
            }
            Spacer()
            Button {
                resetToDefault()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Reset to Default")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Theme.bgChip))
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.green.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Theme.green.opacity(0.2), lineWidth: 1)
                )
        )
    }

    private func themeCard(_ preset: ThemePreset) -> some View {
        let preview = GrizzyThemePalette.fromOsaurus(preset.colors, isDark: preset.isDark)
        let active = isActive(preset)

        return VStack(spacing: 0) {
            ThemePreviewMockup(palette: preview)
                .frame(height: 124)
                .overlay(alignment: .topTrailing) {
                    if active {
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 9, weight: .bold))
                            Text("Active")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(preview.orange))
                        .padding(8)
                    }
                }

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textBright)
                    Text("by \(preset.author)")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                }

                HStack(spacing: 6) {
                    if preset.isSystem {
                        badge("Auto Dark/Light", color: Theme.orange)
                    } else if preset.id != ThemePresets.grizzy.id {
                        badge("Built-in", color: Theme.textSecondary)
                    } else {
                        badge("Grizzy", color: Theme.textSecondary)
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 6) {
                    swatch(preview.bgSidebar)
                    swatch(preview.bgMain)
                    swatch(preview.orange)
                    swatch(preview.green)
                    swatch(preview.textPrimary)
                }

                Button {
                    apply(preset)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: active ? "checkmark.circle.fill" : "paintbrush.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text(active ? "Active" : "Apply Theme")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(active ? Theme.green : Theme.textCream)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(active ? Theme.green.opacity(0.14) : preview.orange)
                    )
                }
                .buttonStyle(.plain)
                .disabled(active)
            }
            .padding(12)
        }
        .background(Theme.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(active ? preview.orange : Theme.borderListRowsAlt, lineWidth: active ? 2 : 1)
        }
        .shadow(color: .black.opacity(active ? 0.12 : 0.07), radius: active ? 10 : 6, y: active ? 4 : 2)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Theme.bgChip))
    }

    private func swatch(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 14, height: 14)
            .overlay(Circle().stroke(Theme.borderListRows, lineWidth: 0.5))
    }

    private func resetToDefault() {
        apply(ThemePresets.grizzy)
    }

    private func apply(_ preset: ThemePreset) {
        if preset.id == ThemePresets.dark.id {
            themeManager.applyAppearanceMode(.dark)
        } else if preset.id == ThemePresets.light.id {
            themeManager.applyAppearanceMode(.light)
        } else if preset.isSystem {
            themeManager.applySystemAppearance()
        } else {
            themeManager.applyPreset(preset)
        }
        var config = store.appConfig
        themeManager.snapshot(for: &config)
        store.saveAppConfig(config)
    }
}

private struct ThemePreviewMockup: View {
    let palette: GrizzyThemePalette

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(palette.bgSelectedRow)
                    .frame(width: 24, height: 4)
                RoundedRectangle(cornerRadius: 2)
                    .fill(palette.bgChip)
                    .frame(width: 20, height: 4)
                RoundedRectangle(cornerRadius: 2)
                    .fill(palette.bgChip.opacity(0.6))
                    .frame(width: 22, height: 4)
            }
            .padding(10)
            .frame(width: 44)
            .background(palette.bgSidebar)

            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(palette.bgCard)
                    .frame(height: 10)
                HStack {
                    Spacer()
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(palette.orange.opacity(0.45))
                        .frame(width: 72, height: 14)
                }
                HStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(palette.bgBubble)
                        .frame(width: 96, height: 14)
                    Spacer()
                }
                HStack {
                    Spacer()
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(palette.bgCard.opacity(0.9))
                        .frame(width: 64, height: 12)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(palette.bgMain)
        }
        .clipShape(RoundedRectangle(cornerRadius: 0))
    }
}

private enum ThemeGalleryFilter: String, CaseIterable, Identifiable {
    case all
    case builtIn
    case grizzy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .builtIn: return "Built-in"
        case .grizzy: return "Grizzy"
        }
    }
}

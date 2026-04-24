import SwiftUI

// MARK: - State

enum TimezoneDensity: String, CaseIterable, Identifiable {
    case compact, regular, comfy
    var id: String { rawValue }
    var rowHeight: CGFloat {
        switch self {
        case .compact: return 60
        case .regular: return 76
        case .comfy:   return 92
        }
    }
    var cityFontSize: CGFloat { self == .compact ? 13 : 15 }
    var clockFontSize: CGFloat { self == .compact ? 20 : 26 }
}

@Observable
final class TimezonePickerState {
    var selectedIds: [String] = ["sfo", "nyc", "lon", "tyo"]
    var query: String = ""

    var dark: Bool = false
    var accent: Color = Color(red: 0x2d / 255, green: 0x7c / 255, blue: 0xf6 / 255)
    var density: TimezoneDensity = .regular
    var use24Hour: Bool = false
    var showOffset: Bool = true
    var showDayNight: Bool = true
    var showMap: Bool = true

    var selectedZones: [TimezoneEntry] {
        selectedIds.compactMap { TimezoneCatalog.byId[$0] }
    }

    func filteredResults() -> [TimezoneEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return TimezoneCatalog.all.filter {
            $0.city.lowercased().contains(q) ||
            $0.region.lowercased().contains(q) ||
            $0.zone.lowercased().contains(q)
        }.prefix(12).map { $0 }
    }

    func add(_ tz: TimezoneEntry) {
        if !selectedIds.contains(tz.id) {
            selectedIds.append(tz.id)
        }
        query = ""
    }

    func remove(_ id: String) {
        selectedIds.removeAll { $0 == id }
    }

    func move(fromIndex: Int, toIndex: Int) {
        guard fromIndex != toIndex,
              selectedIds.indices.contains(fromIndex),
              toIndex >= 0, toIndex < selectedIds.count else { return }
        let moved = selectedIds.remove(at: fromIndex)
        selectedIds.insert(moved, at: toIndex)
    }
}

// MARK: - Palette

private struct TimezonePalette {
    let appBackground: Color
    let ink: Color
    let muted: Color
    let border: Color
    let rowBackground: Color
    let rowBackgroundDragging: Color
    let searchBackground: Color
    let resultsBackground: Color
    let resultsBorder: Color

    static func make(dark: Bool) -> TimezonePalette {
        if dark {
            return TimezonePalette(
                appBackground: Color(red: 0x1c / 255, green: 0x1c / 255, blue: 0x1e / 255),
                ink: Color(red: 0xf2 / 255, green: 0xf2 / 255, blue: 0xf7 / 255),
                muted: Color(red: 235/255, green: 235/255, blue: 245/255).opacity(0.55),
                border: Color.white.opacity(0.09),
                rowBackground: Color.white.opacity(0.04),
                rowBackgroundDragging: Color.white.opacity(0.10),
                searchBackground: Color.white.opacity(0.06),
                resultsBackground: Color(red: 44/255, green: 44/255, blue: 46/255).opacity(0.96),
                resultsBorder: Color.white.opacity(0.10)
            )
        } else {
            return TimezonePalette(
                appBackground: Color(red: 0xf6 / 255, green: 0xf5 / 255, blue: 0xf2 / 255),
                ink: Color(red: 0x1c / 255, green: 0x1c / 255, blue: 0x1e / 255),
                muted: Color(red: 60/255, green: 60/255, blue: 67/255).opacity(0.6),
                border: Color.black.opacity(0.08),
                rowBackground: Color.white.opacity(0.72),
                rowBackgroundDragging: Color.white.opacity(0.95),
                searchBackground: Color.black.opacity(0.04),
                resultsBackground: Color.white.opacity(0.98),
                resultsBorder: Color.black.opacity(0.08)
            )
        }
    }
}

// MARK: - Time helpers

private enum TimezoneTimeFormatter {
    static func components(date: Date, zone: String, use24Hour: Bool) -> (time: String, ampm: String, date: String) {
        guard let tz = TimeZone(identifier: zone) else {
            return ("—:—", "", "")
        }
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.timeZone = tz
        timeFormatter.dateFormat = use24Hour ? "HH:mm" : "h:mm"

        let ampmFormatter = DateFormatter()
        ampmFormatter.locale = Locale(identifier: "en_US_POSIX")
        ampmFormatter.timeZone = tz
        ampmFormatter.dateFormat = "a"

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US")
        dateFormatter.timeZone = tz
        dateFormatter.dateFormat = "EEE, MMM d"

        return (
            timeFormatter.string(from: date),
            use24Hour ? "" : ampmFormatter.string(from: date),
            dateFormatter.string(from: date)
        )
    }

    static func hourInZone(date: Date, zone: String) -> Int {
        guard let tz = TimeZone(identifier: zone) else { return 12 }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        return calendar.component(.hour, from: date)
    }

    static func offsetFromLocal(date: Date, zone: String) -> Double {
        guard let tz = TimeZone(identifier: zone) else { return 0 }
        let remote = TimeInterval(tz.secondsFromGMT(for: date))
        let local = TimeInterval(TimeZone.current.secondsFromGMT(for: date))
        return (remote - local) / 3600.0
    }

    static func formatDelta(_ hours: Double) -> String {
        if abs(hours) < 0.0001 { return "same time" }
        let sign = hours > 0 ? "+" : "−"
        let abs = Swift.abs(hours)
        let hh = Int(abs)
        let mm = Int((abs - Double(hh)) * 60.0 + 0.5)
        let hrText: String
        if mm != 0 {
            hrText = String(format: "%d:%02d", hh, mm)
        } else {
            hrText = "\(hh)"
        }
        let unit = (Swift.abs(hours) == 1 && mm == 0) ? "hr" : "hrs"
        return "\(sign)\(hrText) \(unit)"
    }
}

private enum DayNight {
    case dawn, day, dusk, night
    var glyph: String {
        switch self {
        case .dawn: return "◐"
        case .day: return "☼"
        case .dusk: return "◑"
        case .night: return "☾"
        }
    }
    static func forHour(_ h: Int) -> DayNight {
        if (6..<9).contains(h) { return .dawn }
        if (9..<18).contains(h) { return .day }
        if (18..<21).contains(h) { return .dusk }
        return .night
    }
    func background(dark: Bool) -> Color {
        switch self {
        case .night:
            return dark ? Color(red: 90/255, green: 110/255, blue: 200/255).opacity(0.25)
                        : Color(red: 40/255, green: 60/255, blue: 140/255).opacity(0.10)
        case .day:
            return dark ? Color(red: 255/255, green: 200/255, blue: 80/255).opacity(0.18)
                        : Color(red: 255/255, green: 190/255, blue: 60/255).opacity(0.18)
        case .dawn, .dusk:
            return dark ? Color(red: 255/255, green: 150/255, blue: 120/255).opacity(0.18)
                        : Color(red: 255/255, green: 140/255, blue: 90/255).opacity(0.14)
        }
    }
}

// MARK: - World Map

private struct WorldMapView: View {
    let pinned: [TimezoneEntry]
    let dark: Bool
    let accent: Color

    private static let continents: [CGRect] = [
        CGRect(x: 0.12, y: 0.22, width: 0.14, height: 0.28),  // N. America west
        CGRect(x: 0.22, y: 0.18, width: 0.10, height: 0.18),  // N. America east
        CGRect(x: 0.26, y: 0.42, width: 0.04, height: 0.10),  // C. America
        CGRect(x: 0.28, y: 0.55, width: 0.08, height: 0.28),  // S. America
        CGRect(x: 0.46, y: 0.12, width: 0.06, height: 0.12),  // Europe
        CGRect(x: 0.46, y: 0.28, width: 0.10, height: 0.20),  // N. Africa
        CGRect(x: 0.50, y: 0.52, width: 0.06, height: 0.22),  // S. Africa
        CGRect(x: 0.58, y: 0.10, width: 0.22, height: 0.22),  // Russia / N. Asia
        CGRect(x: 0.60, y: 0.32, width: 0.10, height: 0.18),  // Middle East / S. Asia
        CGRect(x: 0.68, y: 0.30, width: 0.14, height: 0.22),  // E. Asia
        CGRect(x: 0.78, y: 0.58, width: 0.12, height: 0.14),  // Australia
    ]

    var body: some View {
        Canvas { context, size in
            let seaDot = dark ? Color.white.opacity(0.18) : Color.black.opacity(0.22)
            let landDot = dark ? Color.white.opacity(0.45) : Color.black.opacity(0.48)

            let stepX: CGFloat = 8
            let stepY: CGFloat = 8
            var y: CGFloat = 2
            while y < size.height {
                var x: CGFloat = 2
                while x < size.width {
                    let nx = x / size.width
                    let ny = y / size.height
                    let inLand = Self.continents.contains { rect in
                        nx >= rect.minX && nx <= rect.maxX && ny >= rect.minY && ny <= rect.maxY
                    }
                    let r: CGFloat = inLand ? 1.1 : 0.7
                    let dotRect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                    let color = inLand ? landDot : seaDot.opacity(0.55)
                    context.fill(Path(ellipseIn: dotRect), with: .color(color))
                    x += stepX
                }
                y += stepY
            }

            for entry in pinned {
                let px = ((entry.longitude + 180) / 360) * size.width
                let py = ((85 - entry.latitude) / 145) * size.height
                let halo = CGRect(x: px - 10, y: py - 10, width: 20, height: 20)
                context.fill(Path(ellipseIn: halo), with: .color(accent.opacity(0.15)))
                let dot = CGRect(x: px - 4, y: py - 4, width: 8, height: 8)
                context.fill(Path(ellipseIn: dot), with: .color(accent))
                context.stroke(Path(ellipseIn: dot), with: .color(.white), lineWidth: 1.2)
            }
        }
    }
}

// MARK: - Row

private struct ZoneRow: View {
    let tz: TimezoneEntry
    let now: Date
    let state: TimezonePickerState
    let palette: TimezonePalette
    let isDragging: Bool
    let onRemove: () -> Void
    let onDragHandle: (DragGesture.Value) -> Void
    let onDragEnded: (DragGesture.Value) -> Void

    @State private var hoveringRemove = false

    var body: some View {
        let comps = TimezoneTimeFormatter.components(date: now, zone: tz.zone, use24Hour: state.use24Hour)
        let hour = TimezoneTimeFormatter.hourInZone(date: now, zone: tz.zone)
        let dn = DayNight.forHour(hour)
        let delta = TimezoneTimeFormatter.offsetFromLocal(date: now, zone: tz.zone)

        HStack(spacing: 0) {
            // Drag handle
            ZStack {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(palette.muted)
                    .opacity(0.55)
            }
            .frame(width: 22)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged(onDragHandle)
                    .onEnded(onDragEnded)
            )
            .onHover { hovering in
                if hovering {
                    NSCursor.openHand.push()
                } else {
                    NSCursor.pop()
                }
            }

            // Day/night glyph
            if state.showDayNight {
                Text(dn.glyph)
                    .font(.system(size: 15))
                    .foregroundStyle(palette.ink)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(dn.background(dark: state.dark)))
                    .padding(.trailing, 12)
            }

            // City + region
            VStack(alignment: .leading, spacing: 2) {
                Text(tz.city)
                    .font(.system(size: state.density.cityFontSize, weight: .semibold))
                    .tracking(-0.15)
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                HStack(spacing: 0) {
                    Text(tz.region)
                    if state.showOffset {
                        Text("  ·  ")
                        Text(TimezoneTimeFormatter.formatDelta(delta))
                            .monospacedDigit()
                    }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(palette.muted)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Clock
            VStack(alignment: .trailing, spacing: 3) {
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text(comps.time)
                        .font(.system(size: state.density.clockFontSize, weight: .light))
                        .tracking(-0.5)
                        .monospacedDigit()
                        .foregroundStyle(palette.ink)
                    Text(state.use24Hour ? "" : comps.ampm)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.muted)
                        .frame(width: 18, alignment: .leading)
                }
                .lineLimit(1)
                Text(comps.date)
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .tracking(0.2)
                    .foregroundStyle(palette.muted)
            }
            .padding(.leading, 12)

            // Remove
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(palette.muted)
                    .frame(width: 22, height: 22)
                    .background(
                        Circle().fill(hoveringRemove
                            ? (state.dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
                            : Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .padding(.leading, 10)
            .onHover { hoveringRemove = $0 }
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .frame(height: state.density.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isDragging ? palette.rowBackgroundDragging : palette.rowBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(palette.border, lineWidth: 0.5)
        )
        .shadow(
            color: isDragging
                ? (state.dark ? Color.black.opacity(0.55) : Color.black.opacity(0.18))
                : Color.clear,
            radius: isDragging ? 18 : 0,
            x: 0,
            y: isDragging ? 12 : 0
        )
        .scaleEffect(isDragging ? 1.015 : 1.0)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: isDragging)
    }
}

// MARK: - Search Results

private struct SearchResultsList: View {
    let query: String
    let results: [TimezoneEntry]
    let selectedIds: [String]
    let palette: TimezonePalette
    let onPick: (TimezoneEntry) -> Void

    @State private var hoveredId: String?

    var body: some View {
        VStack(spacing: 0) {
            if results.isEmpty {
                Text("No cities match “\(query)”.")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .padding(.horizontal, 14)
            } else {
                ForEach(Array(results.enumerated()), id: \.element.id) { pair in
                    let tz = pair.element
                    let isSelected = selectedIds.contains(tz.id)
                    let isHovered = hoveredId == tz.id && !isSelected

                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(tz.city)
                                .font(.system(size: 13, weight: .medium))
                                .tracking(-0.07)
                                .foregroundStyle(palette.ink)
                                .lineLimit(1)
                            Text("\(tz.region)  ·  \(tz.zone)")
                                .font(.system(size: 11))
                                .foregroundStyle(palette.muted)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if isSelected {
                            Text("ADDED")
                                .font(.system(size: 10.5, weight: .medium))
                                .tracking(0.4)
                                .foregroundStyle(palette.muted)
                        } else {
                            Image(systemName: "plus")
                                .font(.system(size: 13, weight: .light))
                                .foregroundStyle(palette.muted)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(isHovered ? (palette.resultsBorder.opacity(0.6)) : Color.clear)
                    .opacity(isSelected ? 0.45 : 1.0)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard !isSelected else { return }
                        onPick(tz)
                    }
                    .onHover { hovering in
                        if hovering {
                            hoveredId = tz.id
                        } else if hoveredId == tz.id {
                            hoveredId = nil
                        }
                    }

                    if pair.offset < results.count - 1 {
                        Rectangle()
                            .fill(palette.resultsBorder)
                            .frame(height: 0.5)
                    }
                }
            }
        }
        .background(palette.resultsBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(palette.resultsBorder, lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 20, x: 0, y: 10)
    }
}

// MARK: - Tweaks Popover

private struct TweaksPopover: View {
    @Bindable var state: TimezonePickerState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Tweaks")
                .font(.system(size: 13, weight: .semibold))

            section("Appearance") {
                Toggle("Dark mode", isOn: $state.dark)
                ColorPicker("Accent", selection: $state.accent, supportsOpacity: false)
                Picker("Density", selection: $state.density) {
                    ForEach(TimezoneDensity.allCases) { d in
                        Text(d.rawValue.capitalized).tag(d)
                    }
                }
                .pickerStyle(.segmented)
            }

            section("Clock") {
                Toggle("24-hour time", isOn: $state.use24Hour)
                Toggle("Show offset", isOn: $state.showOffset)
                Toggle("Day/night icon", isOn: $state.showDayNight)
            }

            section("Layout") {
                Toggle("Show world map", isOn: $state.showMap)
            }
        }
        .padding(16)
        .frame(width: 260)
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            content()
        }
    }
}

// MARK: - Main View

struct TimezonePickerView: View {
    @State private var state = TimezonePickerState()
    @State private var now = Date()
    @State private var searchFocused = false
    @FocusState private var searchFieldFocused: Bool
    @State private var showTweaks = false

    // Drag state
    @State private var draggingId: String?
    @State private var dragFromIndex: Int = 0
    @State private var dragCurrentIndex: Int = 0
    @State private var dragDy: CGFloat = 0

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var rowGap: CGFloat { 8 }

    var body: some View {
        let palette = TimezonePalette.make(dark: state.dark)

        VStack(spacing: 0) {
            toolbar(palette: palette)

            if state.showMap {
                mapStrip(palette: palette)
            }

            searchBar(palette: palette)
                .zIndex(10)

            zoneList(palette: palette)
        }
        .background(palette.appBackground)
        .foregroundStyle(palette.ink)
        .frame(minWidth: 520, minHeight: 720)
        .preferredColorScheme(state.dark ? .dark : .light)
        .onReceive(timer) { now = $0 }
    }

    // MARK: Toolbar

    @ViewBuilder
    private func toolbar(palette: TimezonePalette) -> some View {
        HStack(spacing: 10) {
            Text("World Clock")
                .font(.system(size: 13, weight: .semibold))
                .tracking(-0.07)
                .foregroundStyle(palette.ink)

            Spacer()

            Text("\(state.selectedIds.count) \(state.selectedIds.count == 1 ? "city" : "cities")")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(palette.muted)

            Button {
                showTweaks.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.ink)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showTweaks, arrowEdge: .bottom) {
                TweaksPopover(state: state)
            }
        }
        .padding(.horizontal, 14)
        .padding(.leading, 68) // leave room for traffic lights on macOS title bar
        .frame(height: 52)
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.border).frame(height: 0.5)
        }
    }

    // MARK: Map strip

    @ViewBuilder
    private func mapStrip(palette: TimezonePalette) -> some View {
        let gradientTop = state.dark
            ? Color(red: 0x16 / 255, green: 0x18 / 255, blue: 0x1c / 255)
            : Color(red: 0xec / 255, green: 0xea / 255, blue: 0xe4 / 255)
        let gradientBottom = palette.appBackground

        WorldMapView(pinned: state.selectedZones, dark: state.dark, accent: state.accent)
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 6)
            .frame(height: 160)
            .background(
                LinearGradient(colors: [gradientTop, gradientBottom],
                               startPoint: .top, endPoint: .bottom)
            )
            .overlay(alignment: .bottom) {
                Rectangle().fill(palette.border).frame(height: 0.5)
            }
    }

    // MARK: Search

    @ViewBuilder
    private func searchBar(palette: TimezonePalette) -> some View {
        @Bindable var bindable = state

        ZStack(alignment: .top) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(palette.muted)

                TextField("Search cities, regions, or time zones", text: $bindable.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(palette.ink)
                    .focused($searchFieldFocused)

                if !state.query.isEmpty {
                    Button {
                        state.query = ""
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(state.dark
                                ? Color(red: 0x1c / 255, green: 0x1c / 255, blue: 0x1e / 255)
                                : Color.white)
                            .frame(width: 16, height: 16)
                            .background(Circle().fill(state.dark
                                ? Color.white.opacity(0.35)
                                : Color.black.opacity(0.35)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(palette.searchBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(searchFieldFocused ? state.accent : Color.clear, lineWidth: 0.5)
            )
            .shadow(color: searchFieldFocused ? state.accent.opacity(0.22) : .clear, radius: 3)
            .animation(.easeInOut(duration: 0.12), value: searchFieldFocused)

            if !state.query.isEmpty {
                SearchResultsList(
                    query: state.query,
                    results: state.filteredResults(),
                    selectedIds: state.selectedIds,
                    palette: palette,
                    onPick: { state.add($0) }
                )
                .frame(maxHeight: 280)
                .fixedSize(horizontal: false, vertical: true)
                .offset(y: 38)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    // MARK: List

    @ViewBuilder
    private func zoneList(palette: TimezonePalette) -> some View {
        let rowHeight = state.density.rowHeight
        let gap = rowGap

        ScrollView {
            if state.selectedZones.isEmpty {
                Text("No cities yet. Search above to add one.")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.muted)
                    .padding(.vertical, 40)
                    .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: gap) {
                    ForEach(Array(state.selectedZones.enumerated()), id: \.element.id) { pair in
                        let index = pair.offset
                        let tz = pair.element
                        let isDragging = draggingId == tz.id
                        let translateY = dragTranslation(
                            for: index,
                            rowHeight: rowHeight,
                            gap: gap,
                            isDragging: isDragging
                        )

                        ZoneRow(
                            tz: tz,
                            now: now,
                            state: state,
                            palette: palette,
                            isDragging: isDragging,
                            onRemove: { state.remove(tz.id) },
                            onDragHandle: { value in
                                handleDragChange(value: value, id: tz.id, fromIndex: index, rowHeight: rowHeight, gap: gap)
                            },
                            onDragEnded: { _ in handleDragEnd() }
                        )
                        .offset(y: translateY)
                        .zIndex(isDragging ? 5 : 1)
                        .animation(isDragging ? nil : .spring(response: 0.36, dampingFraction: 0.85), value: translateY)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 20)
    }

    private func dragTranslation(for index: Int, rowHeight: CGFloat, gap: CGFloat, isDragging: Bool) -> CGFloat {
        if isDragging {
            return dragDy
        }
        guard draggingId != nil else { return 0 }
        if dragFromIndex < dragCurrentIndex,
           index > dragFromIndex, index <= dragCurrentIndex {
            return -(rowHeight + gap)
        }
        if dragFromIndex > dragCurrentIndex,
           index < dragFromIndex, index >= dragCurrentIndex {
            return rowHeight + gap
        }
        return 0
    }

    private func handleDragChange(value: DragGesture.Value, id: String, fromIndex: Int, rowHeight: CGFloat, gap: CGFloat) {
        if draggingId != id {
            draggingId = id
            dragFromIndex = fromIndex
            dragCurrentIndex = fromIndex
        }
        let dy = value.translation.height
        let step = rowHeight + gap
        let over = fromIndex + Int((dy / step).rounded())
        dragCurrentIndex = max(0, min(state.selectedIds.count - 1, over))
        dragDy = dy
    }

    private func handleDragEnd() {
        let from = dragFromIndex
        let to = dragCurrentIndex
        draggingId = nil
        dragDy = 0
        if from != to {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                state.move(fromIndex: from, toIndex: to)
            }
        }
    }
}

#Preview {
    TimezonePickerView()
        .frame(width: 520, height: 720)
}

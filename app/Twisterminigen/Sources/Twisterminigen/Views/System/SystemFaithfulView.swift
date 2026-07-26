import SwiftUI
import AppKit
import MLX

// ============================================================
//  System — telemetry dashboard (maket frame i), now LIVE.
//  Flat steel cards from the maket + real telemetry (CPU/GPU/
//  RAM/MLX/Disk with sparklines & meters) + Typhoon-style
//  maintenance actions and a rolling log. NOTHING is hardcoded:
//  every value comes from TelemetryService / the gallery store.
// ============================================================

/// Sub-label muted grey (#697079) — darker than fxText3; no token, so literal.
private let fxSubMuted = Color(hex: 0x697079)

/// App-wide maintenance and diagnostic log — persists across tab switches and app launches.
@MainActor @Observable
final class SystemLog {
    static let shared = SystemLog()
    private(set) var lines: [String] = []
    private(set) var lastStatus: String?
    private let fileURL: URL

    init(fileURL: URL = AppPaths.systemLog) {
        self.fileURL = fileURL
        load()
    }

    func log(_ msg: String) {
        let bounded = String(msg.prefix(4_096))
        lastStatus = bounded
        lines.append("\(Self.stamp.string(from: Date()))  \(bounded)")
        if lines.count > 200 { lines.removeFirst(lines.count - 200) }
        persist()
    }

    func clear(status: String? = nil) {
        lines.removeAll()
        lastStatus = status
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              data.count <= 1_048_576,
              let stored = try? JSONDecoder().decode([String].self, from: data) else {
            return
        }
        lines = stored.suffix(200).map { String($0.prefix(4_192)) }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(lines)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            lastStatus = "Log persistence failed: \(error.localizedDescription)"
        }
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
}

struct SystemFaithfulView: View {
    @Bindable var telemetry: TelemetryService
    @Bindable var gallery: GalleryViewModel
    @Bindable var models: ModelsViewModel
    @Bindable var lora: LoRAViewModel
    @Bindable var inference: InferenceCoordinator
    @Bindable var generate: GenerateViewModel

    @Environment(AppAccessibilityPreferences.self) private var accessibilityPreferences
    @Environment(AppThemePreferences.self) private var themePreferences
    @Environment(\.fxTheme) private var theme

    @State private var log = SystemLog.shared
    @State private var confirmRemoveAll = false
    @State private var showsStorageManager = false
    @State private var wideRowWidth: CGFloat = 0

    fileprivate enum LayoutMetrics {
        static let rowSpacing: CGFloat = 14
        static let metricVisualHeight: CGFloat = 22
        static let actionHeight: CGFloat = 36
        static let actionWidth: CGFloat = 190
    }

    private var subMutedText: Color {
        theme == .glass ? FxGlassPalette.text3 : fxSubMuted
    }

    private var secondaryText: Color {
        theme == .glass ? FxGlassPalette.text2 : Color.fxText2
    }

    private var tertiaryText: Color {
        theme == .glass ? FxGlassPalette.text3 : Color.fxText3
    }

    private var cardRadius: CGFloat {
        theme == .glass ? FxGlassRadius.card : FxRadius.card
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                themePanel
                statGrid
                wideRow
                accessibilityPanel
                releasePolicyPanel
                maintenance
                logsPanel
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .fxPageBackground()
        .task {
            telemetry.start()
            _ = await gallery.reloadAndWait()
            if let report = await gallery.consumeStartupRecoveryReport(), report.hasActivity {
                logReport(report, prefix: "Startup recovery")
            }
        }
        .alert("Remove all generated images?", isPresented: $confirmRemoveAll) {
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier("system.remove-all.cancel")
                .help("Keep every generated image and thumbnail.")
            Button("Remove all", role: .destructive) { Task { await removeAllData() } }
                .accessibilityIdentifier("system.remove-all.confirm")
                .help("Permanently remove every generated Gallery image after this confirmation.")
        } message: {
            Text("Deletes every PNG in the gallery and its thumbnails. This can't be undone.")
        }
        .sheet(isPresented: publicationReportIsPresented) {
            if let report = gallery.publicationReport {
                GalleryPublicationReportSheet(
                    report: report,
                    onDone: gallery.dismissPublicationReport)
            }
        }
        .sheet(isPresented: $showsStorageManager) {
            StorageManagerView(
                manager: StorageManager(),
                deletionDisabled: inference.isBusy
                    || models.isSwitchingRoot
                    || models.isRefreshing
                    || lora.isWorking
            ) {
                _ = await gallery.reloadAfterStorageManagerChange()
                models.refresh()
                await lora.reloadAfterStorageManagerChange()
            }
        }
    }

    private var publicationReportIsPresented: Binding<Bool> {
        Binding(
            get: { gallery.publicationReport != nil },
            set: { if !$0 { gallery.dismissPublicationReport() } })
    }

    // ── Persisted app appearance ────────────────────────────────────────────────
    private var themePanel: some View {
        @Bindable var themePreferences = themePreferences

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    capsLabel("Theme")
                    Text("Choose the workspace appearance. Changes apply immediately and are remembered.")
                        .fxFont(10.5)
                        .foregroundStyle(theme == .glass ? FxGlassPalette.text3 : fxSubMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Picker("Application theme", selection: $themePreferences.selection) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.title)
                            .tag(theme)
                            .accessibilityIdentifier("theme.option.\(theme.rawValue)")
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 300)
                .accessibilityLabel("Application theme")
                .accessibilityIdentifier("theme.selector")
                .help("Choose Dark, Light, or Glass for the whole app.")
            }

            HStack(spacing: 8) {
                Image(systemName: themeIcon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.fxAccent)
                Text(themePreferences.selection.summary)
                    .fxFont(11.5)
                    .foregroundStyle(theme == .glass ? FxGlassPalette.text2 : Color.fxText2)
            }
            .animation(.easeOut(duration: 0.16), value: themePreferences.selection)
        }
        .cardChrome()
    }

    private var themeIcon: String {
        switch themePreferences.selection {
        case .dark: "moon.stars.fill"
        case .light: "sun.max.fill"
        case .glass: "sparkles"
        }
    }

    // ── App-specific accessibility overrides ───────────────────────────────────
    private var accessibilityPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                capsLabel("Interface & accessibility")
                Spacer(minLength: 0)
                Text("\(accessibilityPreferences.textScalePercent)% text")
                    .fxMonoFont(11, weight: .semibold)
                    .foregroundStyle(Color.fxAccent)
                    .accessibilityLabel("App text scale")
                    .accessibilityValue("\(accessibilityPreferences.textScalePercent) percent")
            }

            FxSlider(
                value: Binding(
                    get: { Double(accessibilityPreferences.textScalePercent) },
                    set: { accessibilityPreferences.textScalePercent = Int($0.rounded()) }),
                range: Double(AppAccessibilityPreferences.minimumTextScalePercent)
                    ... Double(AppAccessibilityPreferences.maximumTextScalePercent),
                step: 5,
                knob: 18,
                track: 5,
                accessibilityLabel: "App text scale",
                accessibilityValue: "\(accessibilityPreferences.textScalePercent) percent",
                accessibilityID: "text-scale.selector")
                .help("Set the app-specific text scale from 85 to 160 percent.")

            HStack(spacing: 22) {
                Toggle(
                    "Reduce transparency",
                    isOn: Binding(
                        get: { accessibilityPreferences.reduceTransparency },
                        set: { accessibilityPreferences.reduceTransparency = $0 }))
                    .accessibilityIdentifier("system.reduce-transparency")
                    .help("Replace translucent app surfaces with more opaque alternatives.")
                Toggle(
                    "Increase contrast",
                    isOn: Binding(
                        get: { accessibilityPreferences.increaseContrast },
                        set: { accessibilityPreferences.increaseContrast = $0 }))
                    .accessibilityIdentifier("system.increase-contrast")
                    .help("Strengthen app borders and focus indicators for clearer separation.")
                Spacer(minLength: 0)
                Button("Reset") { accessibilityPreferences.reset() }
                    .buttonStyle(FxSecondaryButtonStyle(height: 30))
                    .help("Restore the app accessibility overrides to their defaults")
                    .accessibilityIdentifier("system.accessibility-reset")
            }
            .toggleStyle(.switch)

            Text("macOS Reduce Transparency and Increase Contrast remain active even when these app overrides are off.")
                .fxFont(10.5)
                .foregroundStyle(subMutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .cardChrome()
    }

    private var releasePolicyPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            capsLabel("Privacy & release policy")
            Label("Generation, OCR, and image review run locally on this Mac.", systemImage: "lock.shield")
            Label("Model and style downloads are the only network-backed workflows.", systemImage: "arrow.down.circle")
            Label("Krea notice, license, provenance, and output review ship with every release.", systemImage: "doc.text.magnifyingglass")
        }
        .fxFont(11.5)
        .foregroundStyle(secondaryText)
        .cardChrome()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("system.privacy-legal")
    }

    // ── Header (live: chip · OS · RAM · uptime · generations) ───────────────────
    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("System")
                    .fxFont(24, weight: .bold).tracking(-0.3)
                    .foregroundStyle(theme == .glass ? FxGlassPalette.text : Color.fxText)
                Text("\(chipName) · \(osVersion) · \(SystemRAM.installedGB) GB · live telemetry ~1.5s")
                    .fxMonoFont(12).foregroundStyle(tertiaryText)
            }
            Spacer(minLength: 0)
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                HStack(spacing: 8) {
                    FxDot(tone: .ok, live: true, size: 7)
                    Text("uptime \(uptimeText(ctx.date.timeIntervalSince(telemetry.launched))) · \(gallery.generations.count) generations")
                        .fxMonoFont(12, weight: .medium).foregroundStyle(secondaryText)
                }
            }
        }
    }

    // ── Compact telemetry dashboard: three equal cards, then a 2/3 + 1/3 row. ──
    // This is the original System hierarchy: it keeps related measurements visible
    // together instead of turning the page into a vertical list of full-width cards.
    private var statGrid: some View {
        let s = telemetry.snapshot
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: LayoutMetrics.rowSpacing) {
                cpuCard(s)
                gpuCard(s)
                ramCard(s)
            }
            VStack(spacing: LayoutMetrics.rowSpacing) {
                cpuCard(s)
                gpuCard(s)
                ramCard(s)
            }
        }
    }

    private func cpuCard(_ s: TelemetrySnapshot) -> some View {
        StatCard(
            label: "CPU",
            value: "\(Int(s.cpuPercent.rounded()))%",
            spark: telemetry.cpuHistory,
            sub: s.cpuCoreCount > 0 ? "\(s.cpuCoreCount)-core CPU" : "CPU")
    }

    private func gpuCard(_ s: TelemetrySnapshot) -> some View {
        StatCard(
            label: "GPU",
            value: "\(Int(s.gpuPercent.rounded()))%",
            dot: true,
            spark: telemetry.gpuHistory,
            sub: gpuSub(s))
    }

    private func ramCard(_ s: TelemetrySnapshot) -> some View {
        StatCard(
            label: "System RAM",
            value: "\(Int((frac(Double(s.systemUsedBytes), Double(s.systemTotalBytes)) * 100).rounded()))%",
            meter: frac(Double(s.systemUsedBytes), Double(s.systemTotalBytes)),
            sub: "\(ByteFormat.string(s.systemUsedBytes)) / \(ByteFormat.string(s.systemTotalBytes)) used")
    }

    private var wideRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: LayoutMetrics.rowSpacing) {
                mlxCard
                    .frame(width: wideColumnWidth(2.0 / 3.0))
                diskCard
                    .frame(width: wideColumnWidth(1.0 / 3.0))
            }
            VStack(spacing: LayoutMetrics.rowSpacing) {
                mlxCard
                diskCard
            }
        }
        .frame(maxWidth: .infinity)
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { wideRowWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { _, width in wideRowWidth = width }
        })
    }

    private func wideColumnWidth(_ fraction: CGFloat) -> CGFloat? {
        wideRowWidth > 0
            ? (wideRowWidth - LayoutMetrics.rowSpacing) * fraction
            : nil
    }

    private var mlxCard: some View {
        let s = telemetry.snapshot
        let pressureOK = s.memoryPressureLevel <= 1
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                capsLabel("MLX memory")
                Spacer(minLength: 8)
                Text(pressureOK ? "pressure normal" : "pressure high")
                    .fxMonoFont(10, weight: .medium)
                    .foregroundStyle(pressureOK ? Color.fxOk : Color.fxDanger)
                    .lineLimit(1)
            }
            HStack(alignment: .bottom, spacing: 14) {
                Text(ByteFormat.string(s.appFootprintBytes))
                    .fxMonoFont(26, weight: .bold)
                    .foregroundStyle(Color.fxOk)
                    .lineLimit(1)
                Meter(
                    value: frac(
                        Double(s.appFootprintBytes),
                        Double(s.systemTotalBytes)),
                    ok: true)
                    .padding(.bottom, 6)
            }
            .padding(.top, 6)
            .padding(.bottom, 8)
            Text("active \(ByteFormat.string(s.appFootprintBytes)) · peak \(ByteFormat.string(telemetry.appMemPeakBytes)) · swap \(ByteFormat.string(s.swapUsedBytes))")
                .fxMonoFont(10, weight: .medium)
                .foregroundStyle(subMutedText)
                .lineLimit(1)
        }
        .cardChrome()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("MLX memory")
        .accessibilityValue(MetricAccessibilitySummary.metric(
            label: "MLX memory",
            value: ByteFormat.string(s.appFootprintBytes),
            detail: "Peak \(ByteFormat.string(telemetry.appMemPeakBytes)); swap \(ByteFormat.string(s.swapUsedBytes)); pressure \(pressureOK ? "normal" : "high")."))
    }

    private var diskCard: some View {
        let s = telemetry.snapshot
        return StatCard(label: "Disk", value: ByteFormat.string(s.diskFreeBytes),
                        meter: frac(Double(s.diskTotalBytes - s.diskFreeBytes), Double(s.diskTotalBytes)),
                        sub: "free of \(ByteFormat.string(s.diskTotalBytes))")
    }

    // ── Maintenance actions ──────────────────────────────────────────────────────
    private var maintenance: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MAINTENANCE")
                .fxMonoFont(10.5, weight: .semibold).tracking(0.5)
                .foregroundStyle(tertiaryText)

            LazyVGrid(
                columns: [GridItem(
                    .adaptive(
                        minimum: LayoutMetrics.actionWidth,
                        maximum: LayoutMetrics.actionWidth),
                    spacing: 10)],
                alignment: .leading,
                spacing: 10
            ) {
                maintButton(
                    "Clear inference cache",
                    accessibilityID: "system.clear-inference-cache",
                    disabled: inference.isBusy,
                    help: inference.isBusy
                        ? "Wait for the current Krea 2 operation to finish before clearing MLX memory."
                        : "Release reusable prompt and MLX memory."
                ) { Task { await clearInferenceCache() } }
                maintButton("Clear thumbnails", accessibilityID: "system.clear-thumbnails") {
                    Task { await clearThumbnails() }
                }
                maintButton(
                    "Storage Manager…",
                    accessibilityID: "system.storage-manager",
                    help: "Inventory every app location, preview exact deletion totals, and export before removal."
                ) {
                    showsStorageManager = true
                }
                maintButton("Clear logs", accessibilityID: "system.clear-logs") {
                    log.clear(status: "Logs cleared.")
                }
                maintButton("Repair library", accessibilityID: "system.repair-library") {
                    Task { await repairLibrary() }
                }
                maintButton(
                    "Open Gallery folder",
                    accessibilityID: "system.open-gallery-folder",
                    help: "Open the managed Gallery Images folder in Finder without exporting copies."
                ) {
                    Task {
                        gallery.operationMessage = nil
                        if await gallery.revealFolder() {
                            log(gallery.operationMessage
                                ?? "Opened the managed Gallery Images folder.")
                        } else {
                            log(gallery.errorMessage
                                ?? "Open Gallery folder failed.")
                        }
                    }
                }
                maintButton(
                    "Remove all data…",
                    accessibilityID: "system.remove-all-data",
                    danger: true,
                    disabled: inference.isBusy,
                    help: inference.isBusy
                        ? "Wait until the current result has finished saving."
                        : "Delete every generated image and thumbnail."
                ) { confirmRemoveAll = true }
            }
            if let msg = log.lastStatus {
                Text(msg).fxFont(11.5).foregroundStyle(tertiaryText)
            }
        }
        .padding(.top, 4)
    }

    // ── Rolling log panel ───────────────────────────────────────────────────────
    private var logsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                HStack(spacing: 7) {
                    FxDot(tone: log.lines.isEmpty ? .idle : .amber, size: 7)
                    Text("Logs").fxMonoFont(11, weight: .semibold).foregroundStyle(secondaryText)
                }
                Spacer(minLength: 0)
                Text("last \(log.lines.count)")
                    .fxMonoFont(10.5).foregroundStyle(tertiaryText)
            }
            if log.lines.isEmpty {
                Text("No logs yet.").fxMonoFont(11).foregroundStyle(tertiaryText)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(log.lines.suffix(8).reversed().enumerated()), id: \.offset) { _, line in
                        Text(line).fxMonoFont(10.5).foregroundStyle(tertiaryText)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fxThemedSurface(.log, radius: cardRadius)
    }

    private func maintButton(_ title: String, accessibilityID: String,
                             danger: Bool = false, disabled: Bool = false,
                             help: String? = nil,
                             _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .fxFont(12.5, weight: .semibold)
                .foregroundStyle(danger
                    ? Color.fxDanger
                    : (theme == .glass ? FxGlassPalette.text : Color.fxText))
                .lineLimit(1)
                .minimumScaleFactor(0.86)
                .frame(maxWidth: .infinity)
                .frame(height: LayoutMetrics.actionHeight)
                .padding(.horizontal, 14)
                .modifier(SystemMaintenanceSurfaceModifier(danger: danger))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityID)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .help(help ?? title)
    }

    // MARK: - Actions (all real; log real results)

    private func clearInferenceCache() async {
        guard !inference.isBusy else {
            log("Inference cache can't be cleared while Krea 2 is working.")
            return
        }
        let before = TelemetryService.footprintGB()
        MLX.Memory.clearCache()
        let after = TelemetryService.footprintGB()
        await generate.clearConditioningCache()
        let freed = max(0, before - after)
        log(freed > 0.05
            ? String(format: "Inference cache cleared — footprint dropped %.1f GB.", freed)
            : "Inference cache cleared — no measurable footprint change.")
    }

    private func clearThumbnails() async {
        do {
            let result = try await gallery.clearThumbnails()
            if result.count > 0 {
                log("Cleared \(result.count) thumbnail item\(result.count == 1 ? "" : "s") — freed \(ByteFormat.string(result.bytes)).")
            } else {
                log("Thumbnails already clear.")
            }
        } catch {
            log("Clear thumbnails failed: \(error.localizedDescription)")
        }
    }

    private func repairLibrary() async {
        do {
            let report = try await gallery.repairLibrary()
            logReport(report, prefix: "Library repair")
        } catch {
            log("Library repair failed: \(error.localizedDescription)")
        }
    }

    private func removeAllData() async {
        guard !inference.isBusy else {
            log("Generated images can't be removed until the current result finishes saving.")
            return
        }
        let before = gallery.generations.count
        do {
            let result = try await gallery.removeAll()
            if result.count > 0 {
                log("Removed all data — deleted \(result.count) image file\(result.count == 1 ? "" : "s"), \(ByteFormat.string(result.bytes)).")
            } else if before > 0 {
                log("Removed \(before) gallery record\(before == 1 ? "" : "s"); no image files were present.")
            } else {
                log("Remove all data — nothing to delete.")
            }
        } catch {
            log("Remove all data failed: \(error.localizedDescription)")
        }
    }

    private func logReport(_ report: LibraryRepairReport, prefix: String) {
        log(report.conciseStatus(prefix: prefix))
        for error in report.errors.prefix(3) {
            log("\(prefix) error: \(error)")
        }
        if report.errors.count > 3 {
            log("\(prefix): \(report.errors.count - 3) more errors.")
        }
    }

    // MARK: - Derived text

    private func log(_ msg: String) { log.log(msg) }

    private var chipName: String {
        let n = telemetry.snapshot.gpuName
        return n.isEmpty ? "Apple Silicon" : n
    }

    private func gpuSub(_ s: TelemetrySnapshot) -> String {
        let pressure = s.memoryPressureLevel <= 1 ? "normal" : "high"
        if s.gpuCoreCount > 0 { return "\(s.gpuCoreCount)-core · Metal · \(pressure)" }
        return "Metal · \(pressure)"
    }

    private func uptimeText(_ interval: TimeInterval) -> String {
        let t = max(0, Int(interval))
        return String(format: "%02d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
    }

    private var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let names = [26: "Tahoe", 15: "Sequoia", 14: "Sonoma"]
        let base = v.minorVersion > 0 ? "macOS \(v.majorVersion).\(v.minorVersion)" : "macOS \(v.majorVersion)"
        if let name = names[v.majorVersion] { return "macOS \(v.majorVersion) \(name)" }
        return base
    }

    private func frac(_ part: Double, _ whole: Double) -> Double {
        whole > 0 ? max(0, min(1, part / whole)) : 0
    }
}

// ── Shared caps-label (UPPERCASE mono, tracked, fxText3) ────────────────────────
private func capsLabel(_ text: String) -> some View {
    SystemCapsLabel(text: text)
}

private struct SystemCapsLabel: View {
    let text: String
    @Environment(\.fxTheme) private var theme

    var body: some View {
        Text(text)
            .fxFont(10.5, weight: .semibold).tracking(0.5).textCase(.uppercase)
            .foregroundStyle(theme == .glass ? FxGlassPalette.text3 : Color.fxText3)
    }
}

// ── Flat translucent stat card (label · big value · spark/meter · sub) ─────────
private struct StatCard: View {
    let label: String
    let value: String
    var valueColor: Color = .fxText
    var dot: Bool = false
    var spark: [Double]? = nil
    var meter: Double? = nil
    var meterOk = false
    let sub: String
    var status: String? = nil
    var statusColor: Color = .fxText3

    @Environment(\.fxTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                capsLabel(label)
                if let status {
                    Spacer(minLength: 8)
                    Text(status)
                        .fxMonoFont(10, weight: .medium)
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                } else if dot {
                    Spacer(minLength: 0)
                    FxDot(tone: .ok, live: true, size: 7)
                }
            }
            Text(value)
                .fxMonoFont(26, weight: .bold).foregroundStyle(valueColor)
                .lineLimit(1)
                .padding(.top, 6).padding(.bottom, 8)
            ZStack {
                if let spark {
                    Sparkline(data: spark, color: .fxAccent, fill: false, lineWidth: 1.6)
                }
                if let meter {
                    Meter(value: meter, ok: meterOk)
                }
            }
            .frame(height: SystemFaithfulView.LayoutMetrics.metricVisualHeight)
            Text(sub)
                .fxMonoFont(10, weight: .medium)
                .foregroundStyle(theme == .glass ? FxGlassPalette.text3 : fxSubMuted)
                .lineLimit(1)
                .padding(.top, 6)
        }
        .cardChrome()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(MetricAccessibilitySummary.metric(
            label: label,
            value: value,
            detail: status.map { "\(sub); \($0)." } ?? sub,
            samples: spark))
    }
}

// ── Card surface: pad 16, radius 14 (natural height, not stretched) ────────────
private extension View {
    func cardChrome() -> some View {
        modifier(SystemCardChromeModifier())
    }
}

private struct SystemCardChromeModifier: ViewModifier {
    @Environment(\.fxTheme) private var theme

    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .fxThemedSurface(
                .card,
                radius: theme == .glass ? FxGlassRadius.card : FxRadius.card)
    }
}

private struct SystemMaintenanceSurfaceModifier: ViewModifier {
    let danger: Bool

    @Environment(\.fxTheme) private var theme

    @ViewBuilder
    func body(content: Content) -> some View {
        let radius = theme == .glass ? FxGlassRadius.button : FxRadius.button
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if theme == .dark, danger {
            content
                .background(Color.fxInset, in: shape)
                .overlay(shape.strokeBorder(Color.fxDanger.opacity(0.45), lineWidth: 1))
        } else {
            content
                .fxThemedSurface(.inset, radius: radius, interactive: true)
                .overlay(shape.strokeBorder(
                    danger ? Color.fxDanger.opacity(0.45) : Color.clear,
                    lineWidth: danger ? 1 : 0))
        }
    }
}

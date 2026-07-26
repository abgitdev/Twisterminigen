import SwiftUI

/// Help — cheat sheet (frame "j"). Reference content is kept honest with the app's actual
/// current capabilities (no describing unbuilt features as if live) — see the reference rows
/// below. "Replay the welcome tour" is a real, working sheet; "What's new" is plain info (there's
/// nowhere for it to navigate to, so it isn't styled as a nav target).
struct HelpView: View {
    @State private var showOnboarding = false
    @Environment(\.fxTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                cards
                reference
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .fxPageBackground()
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(onDismiss: { showOnboarding = false })
        }
    }

    // ── H1 + subtitle ─────────────────────────────────────────────────────────
    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Help")
                .fxFont(24, weight: .bold)
                .tracking(-0.3)
                .foregroundStyle(theme == .glass ? FxGlassPalette.text : Color.fxText)
            Text("Complete local workflow reference — start with License & Models")
                .fxFont(12)
                .foregroundStyle(theme == .glass ? FxGlassPalette.text3 : Color.fxText3)
        }
    }

    // ── Two wide cards — one a real action, one plain info (nothing to navigate to) ───────────
    @ViewBuilder
    private var cards: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                tourCard
                whatsNewCard
            }
            VStack(spacing: 14) {
                tourCard
                whatsNewCard
            }
        }
    }

    private var tourCard: some View {
        Button { showOnboarding = true } label: {
            HelpActionCard(
                icon: "safari",
                iconTone: .accent,
                title: "Replay the welcome tour",
                subtitle: "License, Models, Generate, Remix, Regions, LoRA, Queue, Presets, Gallery, tools, System and privacy",
                subtitleColor: .fxHdrMuted,
                chevronColor: .fxAccent,
                accent: true,
                showsChevron: true
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("help.onboarding")
        .help("Replay the interactive welcome tour from the beginning.")
    }

    private var whatsNewCard: some View {
        HelpActionCard(
            icon: "sparkle",
            iconTone: .neutral,
            title: "What's new in 1.0",
            subtitle: "Character Sheet presets, live preview controls, clear canvas, editable Regions and Storage Manager",
            subtitleColor: .fxText3,
            chevronColor: .fxText3,
            accent: false,
            showsChevron: false
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("help.release-notices")
    }

    // ── Scannable reference cards. Wide Help is a deliberate 3-column table rather than an
    // adaptive masonry-like spread: every topic has a stable position and each row shares height.
    private var reference: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 14) {
            ForEach(0..<HelpReferenceLayout.rowCount, id: \.self) { row in
                GridRow(alignment: .top) {
                    ForEach(0..<HelpReferenceLayout.columnCount, id: \.self) { column in
                        let section = Self.referenceSections[
                            HelpReferenceLayout.index(row: row, column: column)]
                        RefSection(title: section.title, rows: section.rows)
                            .frame(maxHeight: .infinity, alignment: .topLeading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("help.sections")
    }

    static let referenceSections: [HelpReferenceSection] = {
        [
            .init(title: "LICENSE & FIRST RUN", rows: [
                .init("Required", "Models → Review & accept… must be completed before model download or any Krea render."),
                .init("Accept", "Read the bundled license and Acceptable Use Policy, select the agreement checkbox, then press Accept terms."),
                .init("Gate", "The current acceptance receipt and verified weights are both required by Generate, Queue, presets and Shortcuts."),
                .init("Changed terms", "A different license identifier or digest invalidates the old receipt and requires a new review."),
            ]),
            .init(title: "MODELS & QUALITY", rows: [
                .init("Default", "mixed-4/8 · balanced 9.8 GB backbone."),
                .init("Best Fidelity", "q8 · near-lossless 14.2 GB backbone with higher memory use."),
                .init("Sources", "Download managed weights, import a verified copy, or link a compatible folder read-only."),
                .init("Verification", "Required files become ready only after exact size and SHA-256 manifest checks."),
            ]),
            .init(title: "GENERATE BASICS", rows: [
                .init("Prompt", "Describe the complete scene. Generate snapshots the recipe; edits made during a run prepare the next image."),
                .init("Describe", "An optional local vision model turns a PNG, JPEG or HEIC reference into an editable prompt."),
                .init("Enhance", "The active local Krea model rewrites the prompt and can be stopped before rendering."),
                .init("Lettering", "Adds a visible-text instruction. Local Vision OCR records the result; exact spelling is not guaranteed."),
            ]),
            .init(title: "CANVAS & RENDER", rows: [
                .init("Canvas", "Use native /16 dimensions and aspect presets. 1024² is reliable; the 2K tier remains experimental."),
                .init("Steps", "Turbo is tuned for ~8. Range 4–12."),
                .init("Seed / batch", "Blank is random; fixed UInt64 is reusable. Batch renders 1–8 images sequentially and advances fixed seeds."),
                .init("Preview", "Shows a coarse latent projection while denoising. Choose Off or Hide preview at any time; it never changes the final image."),
                .init("Result actions", "Export, delete, fit and full-size act on the shown result; Clear canvas only hides it and keeps Gallery intact."),
            ]),
            .init(title: "REMIX / IMG2IMG", rows: [
                .init("Source", "Import PNG, JPEG, HEIC, or start from a saved Gallery image."),
                .init("Strength", "Lower values preserve more of the source; 1.00 is pure prompt generation."),
                .init("Geometry", "Choose a normalized crop, then Fit, Fill or Stretch before the recipe is snapshotted."),
                .init("Managed", "The private source copy is bound by UUID and SHA-256; missing or changed dependencies fail closed."),
                .init("Status", "Twister extension — not an official Krea editing pipeline."),
            ]),
            .init(title: "REGIONAL PROMPTS", rows: [
                .init("Global", "The global prompt applies to the complete canvas and remains editable inside the Regions sheet."),
                .init("Regions", "Place up to eight prompt rectangles by dragging or entering exact X, Y, W and H percentages."),
                .init("Order", "Reorder regions to control overlap precedence; order is persisted in the recipe."),
                .init("Limit", "Experimental Turbo CFG 0 only; boundaries are soft and identity isolation is not guaranteed."),
            ]),
            .init(title: "LORA", rows: [
                .init("Ready-made only", "Import compatible adapters; Twisterminigen intentionally does not train LoRAs."),
                .init("Import", "Local .safetensors files are verified and copied into the private library."),
                .init("Krea styles", "Official pinned style downloads require Krea license acceptance."),
                .init("Stack", "Order up to 8 adapters, set scale 0.05–2.00 and optionally insert saved trigger phrases."),
            ]),
            .init(title: "QUEUE", rows: [
                .init("Snapshots", "Jobs store complete immutable recipes and pending work survives relaunch or an interrupted claim."),
                .init("Edit", "Pencil edits a pending recipe; Return opens an editable Generate copy without mutating the queued snapshot."),
                .init("Duplicate", "Create copies with the same, incremented or fresh random seed."),
                .init("Run / stop", "Run All saves each result before the next job. Stop after this preserves the untouched suffix."),
                .init("Preview", "Choose Off, Every 4 steps or Every step from the Queue header, including while it runs."),
            ]),
            .init(title: "QUEUE LAB", rows: [
                .init("Grid", "Preview deterministic seed, step, Remix-strength or LoRA-scale sweeps of up to 64 jobs."),
                .init("Review", "Every planned cell exposes its exact changed value before anything is enqueued."),
                .init("Atomic add", "A valid grid is added as one ordered operation; an invalid grid adds nothing."),
            ]),
            .init(title: "PRESETS", rows: [
                .init("Library", "Search cards, filter Favorites, create personal sections and use managed covers."),
                .init("Complete", "Cards retain prompt, canvas, seed, model, LoRA, Regions and Remix dependencies."),
                .init("Apply / Queue", "Apply loads Generate without rendering; Add to Queue keeps Generate unchanged."),
                .init("Character Sheet", "Wide single-render recipes compose front, back and close-up panels in one 16:9 image."),
            ]),
            .init(title: "GALLERY", rows: [
                .init("Find", "Search and filter by model, capture, LoRA, resolution or date; mark Favorites and group experiments."),
                .init("Inspect", "Use Fit or 100%, copy prompts, review lineage and timing, or compare selected recipes field by field."),
                .init("Reuse", "Use settings, start Remix, save a preset or export a portable .twisterrecipe with dependency checks."),
                .init("Selection", "Bulk export and delete are explicit; managed originals stay private until you choose an action."),
            ]),
            .init(title: "IMAGE TOOLS & EXPORT", rows: [
                .init("Palette", "Extract dominant colours, select swatches and copy or load a reviewed prompt modifier."),
                .init("Cut-out", "Apple Vision creates a local transparent preview; no PNG is written until Save PNG."),
                .init("AI 4×", "Optional tiled SRVGG/Real-ESRGAN requires separate verified weights and license acceptance; it may invent detail."),
                .init("Review", "Derived images never replace the Gallery original and stay private until reviewed and exported."),
            ]),
            .init(title: "SYSTEM & STORAGE", rows: [
                .init("Telemetry", "Live CPU, GPU, RAM, MLX, disk, uptime and persistent diagnostic logs."),
                .init("Appearance", "Dark, Light or Glass; text scale 85–160%; transparency and contrast overrides."),
                .init("Maintenance", "Clear inference cache or thumbnails, repair the library and reveal the managed Gallery folder."),
                .init("Storage Manager", "Inventory locations, calculate an exact dry-run and optionally export selected files before confirmed deletion."),
            ]),
            .init(title: "PRIVACY & SAFETY", rows: [
                .init("Local", "Generation, Enhance, Describe, OCR, palette, cut-out and optional upscale run on this Mac."),
                .init("Network", "Used only for explicit downloads of pinned model or official style files."),
                .init("Screening", "All render entry points locally screen requested output; negative exclusions are not treated as requests."),
                .init("Provenance", "External publication requires visible review and records the supported AI provenance metadata."),
            ]),
            .init(title: "SHORTCUTS", rows: [
                .init("⌘ ↵", "Generate", mono: true),
                .init("Esc / Stop", "Waits for the current Metal operation, then stops.", mono: true),
                .init("⌘ 1…8", "Open Generate, Queue, Gallery, Presets, Models, LoRA, System or Help.", mono: true),
                .init("Hover", "Every important control exposes a concise help explanation."),
            ]),
        ]
    }()
}

// ── Wide action card ──────────────────────────────────────────────────────────
private struct HelpActionCard: View {
    enum IconTone { case accent, neutral }

    let icon: String
    let iconTone: IconTone
    let title: String
    let subtitle: String
    let subtitleColor: Color
    let chevronColor: Color
    let accent: Bool
    /// Only a real nav/action target gets the chevron affordance — a plain info card (nothing to
    /// tap through to) doesn't get styled like one that is.
    let showsChevron: Bool

    @Environment(\.fxTheme) private var theme

    var body: some View {
        HStack(spacing: 14) {
            iconBadge
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fxFont(13.5, weight: .semibold)
                    .foregroundStyle(theme == .glass ? FxGlassPalette.text : Color.fxText)
                Text(subtitle)
                    .fxFont(11.5)
                    .foregroundStyle(resolvedSubtitleColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(chevronColor)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(HelpCardSurfaceModifier(accent: accent))
    }

    private var resolvedSubtitleColor: Color {
        guard theme == .glass else { return subtitleColor }
        return accent ? FxGlassPalette.headerMuted : FxGlassPalette.text3
    }

    private var iconBadge: some View {
        Group {
            if iconTone == .accent {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Color.fxOnAccent)
                    .frame(width: 40, height: 40)
                    .background(
                        LinearGradient(colors: [Color.fxAccent, Color.fxAccentDeep],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                    )
            } else {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(theme == .glass ? FxGlassPalette.text2 : Color.fxText2)
                    .frame(width: 40, height: 40)
                    .modifier(HelpNeutralIconSurfaceModifier())
            }
        }
    }
}

// ── Reference section (label + term/description rows) ──────────────────────────
struct RefRow: Identifiable {
    let id = UUID()
    let term: String
    let desc: String
    let mono: Bool
    init(_ term: String, _ desc: String, mono: Bool = false) {
        self.term = term; self.desc = desc; self.mono = mono
    }
}

struct HelpReferenceSection {
    let title: String
    let rows: [RefRow]
}

enum HelpReferenceLayout {
    static let columnCount = 3
    static let rowCount = 5
    static let sectionCount = columnCount * rowCount

    static func index(row: Int, column: Int) -> Int {
        (row * columnCount) + column
    }
}

private struct RefSection: View {
    let title: String
    let rows: [RefRow]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.fxTheme) private var theme

    private var usesStackedLayout: Bool {
        AccessibilityLayoutPolicy.usesStackedLayout(for: dynamicTypeSize)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .fxMonoFont(11, weight: .semibold)
                .tracking(0.8)
                .foregroundStyle(Color.fxAccent)
                .padding(.bottom, 2)   // label margin-bottom 10 = 8 spacing + 2
            ForEach(rows) { row in
                referenceRow(row)
            }
        }
        .padding(14)
        .frame(
            maxWidth: .infinity,
            minHeight: 132,
            maxHeight: .infinity,
            alignment: .topLeading)
        .fxThemedSurface(.card, radius: 10)
    }

    @ViewBuilder
    private func referenceRow(_ row: RefRow) -> some View {
        if usesStackedLayout {
            VStack(alignment: .leading, spacing: 3) {
                referenceTerm(row)
                referenceDescription(row)
            }
        } else {
            HStack(alignment: .top, spacing: 14) {
                referenceTerm(row)
                    .frame(width: 120, alignment: .leading)
                referenceDescription(row)
            }
        }
    }

    private func referenceTerm(_ row: RefRow) -> some View {
        Text(row.term)
            .fxFont(
                row.mono ? 11.5 : 12,
                weight: .semibold,
                monospaced: row.mono)
            .foregroundStyle(theme == .glass ? FxGlassPalette.text : Color.fxText)
    }

    private func referenceDescription(_ row: RefRow) -> some View {
        Text(row.desc)
            .fxFont(12)
            .lineSpacing(6)
            .foregroundStyle(theme == .glass ? FxGlassPalette.text3 : Color.fxText3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HelpCardSurfaceModifier: ViewModifier {
    let accent: Bool

    @Environment(\.fxTheme) private var theme

    @ViewBuilder
    func body(content: Content) -> some View {
        let radius = theme == .glass ? FxGlassRadius.card : FxRadius.card
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if theme == .dark {
            content
                .background(accent ? Color.fxAccent.opacity(0.09) : Color.fxCardFill, in: shape)
                .overlay(shape.strokeBorder(
                    accent ? Color.fxAccent.opacity(0.28) : Color.fxBorder,
                    lineWidth: 1))
        } else {
            content
                .fxThemedSurface(.card, radius: radius, interactive: accent)
                .overlay(shape.fill(accent ? Color.fxAccent.opacity(0.045) : Color.clear)
                    .allowsHitTesting(false))
                .overlay(shape.strokeBorder(
                    accent ? Color.fxAccent.opacity(0.28) : Color.clear,
                    lineWidth: accent ? 1 : 0))
        }
    }
}

private struct HelpNeutralIconSurfaceModifier: ViewModifier {
    @Environment(\.fxTheme) private var theme

    @ViewBuilder
    func body(content: Content) -> some View {
        if theme == .dark {
            content.background(
                Color.white.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        } else {
            content.fxThemedSurface(.inset, radius: 11, bordered: false)
        }
    }
}

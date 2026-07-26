import SwiftUI

/// Stable first-run policy kept outside SwiftUI so launch routing is deterministic and testable.
enum OnboardingLaunchPolicy {
    static let hasSeenKey = "hasSeenOnboarding.v2"

    static func initialSection(
        modelsReady: Bool,
        environmentOverride: String? = nil
    ) -> AppSection {
        if let environmentOverride,
           let overridden = AppSection(rawValue: environmentOverride) {
            return overridden
        }
        return modelsReady ? .generate : .models
    }

    static func shouldPresent(defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: hasSeenKey)
    }

    static func markSeen(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: hasSeenKey)
    }
}

/// Short, skippable pages that mirror the app's complete local workflow.
/// The caller owns first-run persistence; replaying the tour from Help does not alter app data.
struct OnboardingView: View {
    let onDismiss: () -> Void

    @State private var pageIndex = 0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.fxTheme) private var theme

    struct Row: Identifiable {
        let term: String
        let detail: String
        var id: String { term }
    }

    struct Page {
        let accessibilityID: String
        let icon: String
        let title: String
        let intro: String
        let rows: [Row]
    }

    static let pages: [Page] = [
        Page(
            accessibilityID: "license-models",
            icon: "checkmark.shield",
            title: "License & Models",
            intro: "Krea 2 cannot be downloaded or used for rendering until you accept the current Krea 2 Community License and Acceptable Use Policy in Models.",
            rows: [
                Row(term: "1 · Review", detail: "Open Models, choose Review & accept…, read the bundled agreement and follow the official policy links."),
                Row(term: "2 · Accept", detail: "Select the agreement checkbox, then press Accept terms. The checkbox alone does not record acceptance."),
                Row(term: "3 · Weights", detail: "Download, import or link the selected tier. Every required file must pass its exact size and SHA-256 checks."),
                Row(term: "Render gate", detail: "Generate, Queue, presets, Shortcuts and official Krea style downloads remain blocked until both acceptance and verified weights are current."),
            ]),
        Page(
            accessibilityID: "generate",
            icon: "wand.and.stars",
            title: "Generate",
            intro: "Build the prompt on the main page, then render locally or save the same immutable recipe for later.",
            rows: [
                Row(term: "Prompt", detail: "Describe the whole scene. Positive, negative and exact-text instructions are saved with the result."),
                Row(term: "Describe", detail: "Install the optional local vision model to turn a PNG, JPEG or HEIC reference into an editable prompt."),
                Row(term: "Enhance", detail: "Let the active local Krea model rewrite the prompt; you can stop it before starting a render."),
                Row(term: "Lettering", detail: "Specify visible text separately. Local Vision OCR records what it sees, but exact spelling is not guaranteed."),
            ]),
        Page(
            accessibilityID: "render-controls",
            icon: "dial.medium",
            title: "Canvas & render controls",
            intro: "Choose the complete recipe before Generate. Running work uses a snapshot, so later edits prepare the next image.",
            rows: [
                Row(term: "Canvas", detail: "Use the native /16 sizes and aspect presets. 1024² is the dependable tier; 2K remains experimental."),
                Row(term: "Quality", detail: "Default mixed-4/8 is balanced; optional Best Fidelity q8 uses more memory. Turbo is tuned near 8 steps, with a 4–12 range."),
                Row(term: "Seed & batch", detail: "Leave seed blank for random, reuse a fixed UInt64, or render 1–8 sequential images; fixed batches advance seed +1."),
                Row(term: "During render", detail: "Live Preview can be Off, every 4 steps or every step. Stop waits for the current Metal operation; Clear canvas never deletes Gallery."),
            ]),
        Page(
            accessibilityID: "remix",
            icon: "photo.badge.arrow.down",
            title: "Remix",
            intro: "Start from a local PNG, JPEG or HEIC, or reuse a verified image from Gallery. Remix is a Twister extension, not an official Krea editing pipeline.",
            rows: [
                Row(term: "Strength", detail: "Lower values preserve more of the source; 1.00 becomes prompt-only generation."),
                Row(term: "Crop", detail: "Choose the normalized source crop before Fit, Fill or Stretch is applied."),
                Row(term: "Managed", detail: "The source is copied into the private library and addressed by UUID plus SHA-256."),
                Row(term: "Recipe", detail: "Strength, crop, resize mode and exact source identity travel with Queue, Presets and portable recipes."),
            ]),
        Page(
            accessibilityID: "regional-prompts",
            icon: "rectangle.3.group",
            title: "Regional prompts",
            intro: "Place up to eight prompt regions on the canvas. Experimental — identity isolation is not guaranteed.",
            rows: [
                Row(term: "Global prompt", detail: "The main scene description remains visible to the whole canvas and can be edited inside the Regions sheet."),
                Row(term: "Regions", detail: "Add, move and resize up to eight normalized rectangles by pointer or exact X/Y/W/H percentages."),
                Row(term: "Order", detail: "Region order is part of the recipe and remains significant when rectangles overlap."),
                Row(term: "CFG", detail: "Regional prompts use the experimental Turbo CFG-0 path only."),
            ]),
        Page(
            accessibilityID: "lora",
            icon: "shippingbox",
            title: "LoRA",
            intro: "Use ready-made compatible adapters only. Twisterminigen imports and applies LoRA files locally; it does not train them.",
            rows: [
                Row(term: "Import", detail: "Drop compatible local .safetensors files; verified copies are stored in the private LoRA library."),
                Row(term: "Krea styles", detail: "The pinned official catalog requires the same Krea license acceptance before download."),
                Row(term: "Stack", detail: "Enable and order up to eight adapters, set scale from 0.05–2.00 and save trigger phrases."),
                Row(term: "Triggers", detail: "Automatic insertion adds enabled trigger phrases to new recipes; inspect the final prompt before rendering."),
            ]),
        Page(
            accessibilityID: "queue",
            icon: "list.bullet.rectangle",
            title: "Queue & Queue Lab",
            intro: "Queue stores exact recipe snapshots and runs them sequentially without losing pending work after relaunch.",
            rows: [
                Row(term: "Pending jobs", detail: "Reorder, remove, edit in place, open an editable Generate copy, or duplicate with fixed, incremented or fresh seeds."),
                Row(term: "Run & stop", detail: "Run All processes one job at a time. Stop after this finishes the current Metal boundary and preserves the untouched suffix."),
                Row(term: "Queue Lab", detail: "Preview deterministic seed, step, Remix-strength or LoRA-scale grids of up to 64 jobs before adding them."),
                Row(term: "Preview", detail: "Choose Off, Every 4 steps or Every step from the Queue header, even while Queue is running."),
            ]),
        Page(
            accessibilityID: "presets",
            icon: "slider.horizontal.3",
            title: "Presets",
            intro: "Save reusable local recipe cards with a managed cover and apply them without starting a render.",
            rows: [
                Row(term: "Library", detail: "Search built-ins, filter Favorites, create personal sections and save personal cards with managed covers."),
                Row(term: "Complete", detail: "Prompt, canvas, seed, quality, LoRA, Regional prompts and Remix dependencies remain in every card."),
                Row(term: "Apply / Queue", detail: "Apply loads an editable Generate copy; Add to Queue stores the exact recipe without changing Generate."),
                Row(term: "Character Sheet", detail: "Its wide cards are single 16:9 renders containing front, back and close-up panels — not three separate jobs."),
            ]),
        Page(
            accessibilityID: "gallery",
            icon: "photo.on.rectangle.angled",
            title: "Gallery",
            intro: "Each successful render is stored with a sidecar containing its validated, versioned recipe.",
            rows: [
                Row(term: "Find", detail: "Search and filter by model, capture quality, LoRA, resolution or date; mark Favorites and group related experiments."),
                Row(term: "Inspect", detail: "Open Fit or 100%, copy the prompt, review lineage and performance, or compare selected recipes field by field."),
                Row(term: "Reuse", detail: "Use settings, start Remix, save a preset or export a portable .twisterrecipe with dependency checks."),
                Row(term: "Manage", detail: "Selection mode supports bulk export and deletion. Export is reviewed; deletion always targets the private originals."),
            ]),
        Page(
            accessibilityID: "image-tools",
            icon: "photo.badge.plus",
            title: "Gallery image tools",
            intro: "Derived tools are explicit local operations. They never replace or silently modify the saved Gallery original.",
            rows: [
                Row(term: "Palette", detail: "Extract dominant colours, select swatches and copy or load the reviewed prompt modifier into Generate."),
                Row(term: "Cut-out", detail: "Apple Vision separates foreground instances locally; a transparent PNG is written only after Save PNG."),
                Row(term: "AI 4×", detail: "Optional tiled SRVGG/Real-ESRGAN uses separate verified weights and its own license acceptance; details may be invented."),
                Row(term: "Export", detail: "Every derived PNG stays private until you review it and choose a destination."),
            ]),
        Page(
            accessibilityID: "system-storage",
            icon: "gauge.with.dots.needle.67percent",
            title: "System & Storage",
            intro: "System shows live health, appearance and maintenance controls; Storage Manager makes cleanup inspectable before deletion.",
            rows: [
                Row(term: "Telemetry", detail: "Monitor CPU, GPU, RAM, MLX, disk, uptime and recent diagnostic logs."),
                Row(term: "Appearance", detail: "Choose Dark, Light or Glass, scale app text from 85–160%, and adjust transparency or contrast."),
                Row(term: "Maintenance", detail: "Clear caches or thumbnails, repair the library, reveal Gallery storage and review persistent logs."),
                Row(term: "Storage Manager", detail: "Inventory app locations, calculate an exact dry-run and optionally export selected files before confirmed removal."),
            ]),
        Page(
            accessibilityID: "privacy",
            icon: "lock.shield",
            title: "Privacy, safety & files",
            intro: "Prompts, recipes, source images and generated images remain on this Mac unless you explicitly export them.",
            rows: [
                Row(term: "Local", detail: "Generation, Enhance, Describe, OCR, cut-out and optional AI upscale run on this Mac."),
                Row(term: "Network", detail: "Used only when you explicitly download pinned model or official style files."),
                Row(term: "Safety", detail: "Every render path screens the requested output locally; exports require visible review and preserve provenance."),
                Row(term: "Portable", detail: "Import and export happen only through your chosen files and destinations; missing dependencies are reported, never dropped."),
            ]),
    ]

    private var isLastPage: Bool { pageIndex == Self.pages.count - 1 }
    private var usesStackedLayout: Bool {
        AccessibilityLayoutPolicy.usesStackedLayout(for: dynamicTypeSize)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                page(Self.pages[pageIndex])
                    .id(pageIndex)
                    .transition(.opacity)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
            .scrollIndicators(.automatic)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            footer
        }
        .padding(24)
        .frame(width: 700, height: 560)
        .fxStandalonePageBackground()
        .animation(.easeInOut(duration: 0.2), value: pageIndex)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.sheet")
        .accessibilityLabel("Welcome tour, page \(pageIndex + 1) of \(Self.pages.count)")
    }

    private func page(_ page: Page) -> some View {
        VStack(spacing: 14) {
            Image(systemName: page.icon)
                .font(.system(size: 44))
                .foregroundStyle(Color.fxAccent)
                .frame(height: 60)
                .padding(.top, 24)
                .accessibilityHidden(true)
            Text(page.title)
                .fxFont(21, weight: .bold)
                .foregroundStyle(theme == .glass ? FxGlassPalette.text : Color.fxText)
            Text(page.intro)
                .fxFont(13)
                .foregroundStyle(theme == .glass ? FxGlassPalette.text2 : Color.fxText2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520)

            VStack(alignment: .leading, spacing: 12) {
                ForEach(page.rows) { row in
                    onboardingRow(row)
                }
            }
            .frame(maxWidth: 570)
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func onboardingRow(_ row: Row) -> some View {
        if usesStackedLayout {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.term)
                    .fxFont(12.5, weight: .semibold)
                    .foregroundStyle(Color.fxAccent)
                Text(row.detail)
                    .fxFont(12.5)
                    .foregroundStyle(theme == .glass ? FxGlassPalette.text2 : Color.fxText2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(row.term)
                    .fxFont(12.5, weight: .semibold)
                    .foregroundStyle(Color.fxAccent)
                    .frame(width: 110, alignment: .trailing)
                Text(row.detail)
                    .fxFont(12.5)
                    .foregroundStyle(theme == .glass ? FxGlassPalette.text2 : Color.fxText2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        Group {
            if usesStackedLayout {
                VStack(spacing: 8) {
                    pageDots
                    footerButtons
                }
            } else {
                ZStack {
                    footerButtons
                    pageDots
                }
            }
        }
        .padding(.top, 16)
    }

    private var footerButtons: some View {
        let controlHeight: CGFloat = usesStackedLayout ? 44 : 32
        return HStack(spacing: 10) {
            Button("Skip tour", action: onDismiss)
                .buttonStyle(FxGhostButtonStyle(height: controlHeight))
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("onboarding.skip")
                .help("Close the tour. It can be replayed from Help.")
            Spacer()
            Button("Back") { pageIndex = max(0, pageIndex - 1) }
                .buttonStyle(FxSecondaryButtonStyle(height: controlHeight))
                .opacity(pageIndex == 0 ? 0 : 1)
                .disabled(pageIndex == 0)
                .accessibilityIdentifier("onboarding.back")
                .help(pageIndex == 0
                      ? "Back is unavailable on the first tour page."
                      : "Return to the previous tour page.")
            if isLastPage {
                Button("Start creating", action: onDismiss)
                    .buttonStyle(FxPrimaryButtonStyle(height: controlHeight))
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("onboarding.start-creating")
                    .help("Close the completed tour and start using Twisterminigen.")
            } else {
                Button("Next") { pageIndex = min(Self.pages.count - 1, pageIndex + 1) }
                    .buttonStyle(FxPrimaryButtonStyle(height: controlHeight))
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("onboarding.next")
                    .help("Continue to the next tour page.")
            }
        }
    }

    private var pageDots: some View {
        HStack(spacing: 3) {
            ForEach(Self.pages.indices, id: \.self) { index in
                Button { pageIndex = index } label: {
                    Circle()
                        .fill(index == pageIndex
                            ? Color.fxAccent
                            : (theme == .glass ? FxGlassPalette.text3 : Color.fxText3))
                        .frame(width: 6, height: 6)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("onboarding.page.\(Self.pages[index].accessibilityID)")
                .accessibilityLabel("Page \(index + 1), \(Self.pages[index].title)")
                .accessibilityValue(index == pageIndex ? "Current page" : "Not current")
                .help(index == pageIndex
                      ? "This is the current tour page."
                      : "Open the \(Self.pages[index].title) tour page.")
            }
        }
    }
}

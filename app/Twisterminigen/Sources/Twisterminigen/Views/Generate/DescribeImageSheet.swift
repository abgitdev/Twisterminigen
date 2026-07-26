import SwiftUI
import UniformTypeIdentifiers

/// Standalone P3 surface. The parent can present it from Generate, Gallery, or a shared Image Tools
/// sheet without coupling Describe to any one screen.
struct DescribeImageSheet: View {
    @Bindable var viewModel: DescribeImageViewModel
    let onUseDescription: (String) -> Void
    let onDismiss: () -> Void

    @State private var choosingImage = false
    @Environment(\.fxTheme) private var theme

    private var secondaryText: Color {
        theme == .glass ? FxGlassPalette.text2 : Color.fxText2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "text.viewfinder")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.fxAccentHi)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Describe Image")
                        .fxFont(17, weight: .semibold)
                    Text("Local image → reusable generation prompt")
                        .fxFont(11)
                        .foregroundStyle(secondaryText)
                }
                Spacer()
                Button("Done", action: onDismiss)
                    .disabled(viewModel.isBusy)
                    .help(viewModel.isBusy
                        ? "Cancel or wait for the current Describe Image operation before closing."
                        : "Close Describe Image")
                    .accessibilityIdentifier("describe-image.done")
            }

            modelSection
            Divider()
            imageSection

            if viewModel.isBusy {
                HStack(spacing: 8) {
                    ProgressView(value: viewModel.progressFraction)
                        .controlSize(.small)
                    Text(viewModel.statusMessage ?? "Working…")
                        .fxMonoFont(10.5)
                        .foregroundStyle(secondaryText)
                    Spacer()
                    Button("Cancel") { viewModel.cancel() }
                        .help("Cancel the current Describe Image operation")
                        .accessibilityIdentifier("describe-image.cancel")
                }
            } else if let error = viewModel.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .fxFont(11)
                    .foregroundStyle(Color.fxDanger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !viewModel.descriptionText.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("DESCRIPTION")
                        .fxMonoFont(10, weight: .semibold)
                        .foregroundStyle(secondaryText)
                    TextEditor(text: $viewModel.descriptionText)
                        .fxFont(12.5)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 150)
                        .modifier(DescribeEditorSurfaceModifier())
                        .accessibilityIdentifier("describe-image.description")
                        .help("Edit the local image description before using it as the generation prompt.")
                    HStack {
                        Spacer()
                        Button("Use as Prompt") {
                            onUseDescription(viewModel.descriptionText)
                        }
                        .buttonStyle(.borderedProminent)
                        .help("Use the editable local description as the generation prompt")
                        .accessibilityIdentifier("describe-image.use-as-prompt")
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 580, minHeight: 420)
        .fxStandalonePageBackground()
        .accessibilityIdentifier("describe-image.sheet")
        .task { await viewModel.refreshModelStatus() }
        .fileImporter(
            isPresented: $choosingImage,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                viewModel.selectImage(url)
            }
        }
        .interactiveDismissDisabled(viewModel.isBusy)
    }

    @ViewBuilder private var modelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(DescribeImageModel.title)
                        .fxFont(12.5, weight: .semibold)
                    Text(modelDetail)
                        .fxMonoFont(10.5)
                        .foregroundStyle(secondaryText)
                }
                Spacer()
                if viewModel.modelIsInstalled {
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .fxFont(11, weight: .semibold)
                        .foregroundStyle(Color.green)
                    Button("Remove") { viewModel.startRemove() }
                        .disabled(viewModel.isBusy)
                        .help(viewModel.isBusy
                            ? "Cancel or wait for the current Describe Image operation before removing the model."
                            : "Remove the local Describe Image model")
                        .accessibilityIdentifier("describe-image.model.remove")
                } else {
                    Button("Install Model") { viewModel.startInstall() }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.isBusy || viewModel.modelStatus == nil)
                        .help(installModelHelp)
                        .accessibilityIdentifier("describe-image.model.install")
                }
            }
            Text("Optional and fully local after installation. It never uploads the selected image and never starts a render.")
                .fxFont(10.5)
                .foregroundStyle(secondaryText)
        }
    }

    @ViewBuilder private var imageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("REFERENCE IMAGE")
                .fxMonoFont(10, weight: .semibold)
                .foregroundStyle(secondaryText)
            HStack(spacing: 10) {
                Image(systemName: viewModel.selectedImageURL == nil ? "photo.badge.plus" : "photo.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.fxAccentHi)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.selectedImageURL?.lastPathComponent ?? "No image selected")
                        .fxFont(12, weight: .medium)
                        .lineLimit(1)
                    Text("PNG, JPEG, HEIF, TIFF, or another macOS-readable image")
                        .fxFont(10.5)
                        .foregroundStyle(secondaryText)
                }
                Spacer()
                Button("Choose…") { choosingImage = true }
                    .disabled(viewModel.isBusy)
                    .help(viewModel.isBusy
                        ? "Cancel or wait for the current Describe Image operation before choosing another image."
                        : "Choose a local reference image")
                    .accessibilityIdentifier("describe-image.choose-image")
            }
            Button {
                viewModel.startDescribe()
            } label: {
                Label("Describe Image", systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canDescribe)
            .help(describeActionHelp)
            .accessibilityIdentifier("describe-image.describe")
        }
    }

    private var installModelHelp: String {
        if viewModel.isBusy {
            return "Cancel or wait for the current Describe Image operation before installing the model."
        }
        if viewModel.modelStatus == nil {
            return "Wait while the local Describe Image model status is checked."
        }
        return "Install the optional local Describe Image model"
    }

    private var describeActionHelp: String {
        if viewModel.isBusy {
            return "Cancel or wait for the current Describe Image operation before starting another description."
        }
        if !viewModel.modelIsInstalled {
            return "Install the local Describe Image model before describing an image."
        }
        if viewModel.selectedImageURL == nil {
            return "Choose a local reference image before describing it."
        }
        if !viewModel.canDescribe {
            return "Wait for the active render or model operation to finish before describing an image."
        }
        return "Describe the selected image locally"
    }

    private var modelDetail: String {
        guard let status = viewModel.modelStatus else { return "Checking local model…" }
        let expected = ByteFormat.string(status.expectedBytes)
        switch status.state {
        case .downloaded: return "\(expected) · verified local cache"
        case .partial: return "\(ByteFormat.string(status.onDiskBytes)) of \(expected) · resumable"
        case .corrupted: return "\(expected) · repair required"
        case .missing: return "\(expected) download · optional"
        }
    }
}

private struct DescribeEditorSurfaceModifier: ViewModifier {
    @Environment(\.fxTheme) private var theme

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        if theme == .dark {
            content
                .background(Color.black.opacity(0.18), in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.1), lineWidth: 1))
        } else {
            content.fxThemedSurface(.log, radius: 10)
        }
    }
}

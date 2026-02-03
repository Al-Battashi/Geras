import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    enum CompressionMode: String, CaseIterable, Identifiable {
        case losslessQPDF
        case ghostscript
        case rasterize

        var id: String { rawValue }

        var title: String {
            switch self {
            case .losslessQPDF:
                return "Clean Up"
            case .ghostscript:
                return "Make Smaller"
            case .rasterize:
                return "Flatten"
            }
        }

        var subtitle: String {
            switch self {
            case .losslessQPDF:
                return "Clean Up (No Quality Loss)"
            case .ghostscript:
                return "Make Smaller (Keeps Text)"
            case .rasterize:
                return "Flatten to Images (Text Becomes Image)"
            }
        }
    }

    @State private var inputURL: URL?
    @State private var outputURL: URL?
    @State private var statusMessage = "Select a PDF to compress."
    @State private var errorMessage: String?
    @State private var isCompressing = false
    @State private var inputSize: Int64?
    @State private var outputSize: Int64?
    @State private var compressionSummary: String?

    @State private var mode: CompressionMode = .losslessQPDF

    @State private var compressionLevel = 5
    @State private var recompressFlate = false
    @State private var generateObjectStreams = true
    @State private var optimizeImages = false

    private let customRecommendedDpi = 150
    private let customRecommendedQuality = 75
    private let highQualityDpi = 225
    private let highQualityQuality = 85

    @State private var gsPreset: GhostscriptPreset = .almostLossless
    @State private var gsDpi = 225
    @State private var gsJpegQuality = 85

    @State private var rasterizeDpi = 120
    @State private var rasterizeQuality = 70

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Geras : PDF Compressor")
                .font(.system(size: 28, weight: .semibold))

            Text("Pick the result you want. We’ll handle the technical details.")
                .foregroundStyle(.secondary)

            Picker("Mode", selection: $mode) {
                ForEach(CompressionMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 12) {
                Button("Choose PDF") {
                    selectInputPDF()
                }
                .buttonStyle(.borderedProminent)

                Button("Choose Output") {
                    selectOutputPDF()
                }
                .buttonStyle(.bordered)
                .disabled(inputURL == nil)

                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Input: \(inputURL?.path ?? "—")")
                    .font(.system(.body, design: .monospaced))
                Text("Input size: \(formattedByteCount(inputSize))")
                    .foregroundStyle(.secondary)

                Text("Output: \(outputURL?.path ?? "—")")
                    .font(.system(.body, design: .monospaced))
                Text("Output size: \(formattedByteCount(outputSize))")
                    .foregroundStyle(.secondary)
            }

            if mode == .losslessQPDF {
                GroupBox(mode.subtitle) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Compression strength")
                            Spacer()
                            Stepper("\(compressionLevel)", value: $compressionLevel, in: 1...9)
                                .frame(width: 140)
                        }

                        Toggle("Deep clean (slower, uses more memory)", isOn: $recompressFlate)
                        Toggle("Improve internal structure (safe)", isOn: $generateObjectStreams)
                        Toggle("Try image optimization (may reduce quality)", isOn: $optimizeImages)

                        Text("Keeps the PDF looking identical. Best when you cannot change quality.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
            }

            if mode == .ghostscript {
                GroupBox(mode.subtitle) {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Preset", selection: $gsPreset) {
                            ForEach(GhostscriptPreset.allCases) { preset in
                                Text(preset.title).tag(preset)
                            }
                        }
                        .pickerStyle(.segmented)

                        if gsPreset == .custom {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Image sharpness (DPI)")
                                    Spacer()
                                    Stepper("\(gsDpi)", value: $gsDpi, in: 72...300, step: 12)
                                        .frame(width: 160)
                                }
                                HStack {
                                    Text("Image quality (JPEG)")
                                    Spacer()
                                    Stepper("\(gsJpegQuality)", value: $gsJpegQuality, in: 20...95, step: 5)
                                        .frame(width: 160)
                                }
                                Text("Recommended: 150 DPI / JPEG 75 for balance, or 225 DPI / JPEG 85 for high quality.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text(gsPreset.description)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        Text("Shrinks images inside the PDF. Text stays selectable.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text("If savings are tiny, the file is likely already optimized or mostly text. Try Flatten for maximum shrink (text becomes image).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
            }

            if mode == .rasterize {
                GroupBox(mode.subtitle) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Image sharpness (DPI)")
                            Spacer()
                            Stepper("\(rasterizeDpi)", value: $rasterizeDpi, in: 72...300, step: 12)
                                .frame(width: 160)
                        }

                        HStack {
                            Text("Image quality (JPEG)")
                            Spacer()
                            Stepper("\(rasterizeQuality)", value: $rasterizeQuality, in: 30...95, step: 5)
                                .frame(width: 160)
                        }

                        Text("Flattens every page into a picture. Text will NOT be selectable or searchable.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
            }

            HStack(spacing: 12) {
                Button(isCompressing ? "Compressing..." : "Compress") {
                    compress()
                }
                .buttonStyle(.borderedProminent)
                .disabled(inputURL == nil || outputURL == nil || isCompressing)

                if isCompressing {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            } else if let compressionSummary {
                Text(compressionSummary)
                    .foregroundStyle(.secondary)
            } else {
                Text(statusMessage)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 420)
        .onChange(of: gsPreset) { preset in
            switch preset {
            case .almostLossless:
                gsDpi = highQualityDpi
                gsJpegQuality = highQualityQuality
            case .custom:
                gsDpi = customRecommendedDpi
                gsJpegQuality = customRecommendedQuality
            case .reallyLossy:
                break
            }
        }
    }

    private func selectInputPDF() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.pdf]

        if panel.runModal() == .OK, let url = panel.url {
            useSamplePDF(url)
        }
    }

    private func selectOutputPDF() {
        guard let inputURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = defaultOutputURL(for: inputURL).lastPathComponent

        if panel.runModal() == .OK, let url = panel.url {
            outputURL = url
            outputSize = fileSize(for: url)
            compressionSummary = nil
        }
    }

    private func compress() {
        guard let inputURL, let outputURL else { return }
        isCompressing = true
        statusMessage = "Running \(mode.title.lowercased())..."
        errorMessage = nil
        compressionSummary = nil

        let completion: (Result<Void, Error>) -> Void = { result in
            DispatchQueue.main.async {
                isCompressing = false
                switch result {
                case .success:
                    statusMessage = "Done. Output saved to \(outputURL.lastPathComponent)"
                    outputSize = fileSize(for: outputURL)
                    compressionSummary = buildCompressionSummary()
                case .failure(let error):
                    errorMessage = error.localizedDescription
                    statusMessage = "Compression failed."
                }
            }
        }

        switch mode {
        case .losslessQPDF:
            let options = QPDFOptions(
                compressionLevel: compressionLevel,
                recompressFlate: recompressFlate,
                generateObjectStreams: generateObjectStreams,
                optimizeImages: optimizeImages
            )
            QPDFService.compress(input: inputURL, output: outputURL, options: options, completion: completion)
        case .ghostscript:
            let options = GhostscriptOptions(
                preset: gsPreset,
                dpi: gsDpi,
                jpegQuality: gsJpegQuality
            )
            GhostscriptService.compress(input: inputURL, output: outputURL, options: options, completion: completion)
        case .rasterize:
            RasterizeService.rasterize(
                input: inputURL,
                output: outputURL,
                dpi: CGFloat(rasterizeDpi),
                jpegQuality: rasterizeQuality,
                completion: completion
            )
        }
    }

    private func useSamplePDF(_ url: URL) {
        inputURL = url
        outputURL = defaultOutputURL(for: url)
        inputSize = fileSize(for: url)
        outputSize = nil
        compressionSummary = nil
        statusMessage = "Ready to compress."
        errorMessage = nil
    }

    private func defaultOutputURL(for inputURL: URL) -> URL {
        let folder = inputURL.deletingLastPathComponent()
        let base = inputURL.deletingPathExtension().lastPathComponent
        let suffix: String
        switch mode {
        case .losslessQPDF:
            suffix = "compressed"
        case .ghostscript:
            suffix = "lossy"
        case .rasterize:
            suffix = "rasterized"
        }
        let name = "\(base)-\(suffix).pdf"
        return folder.appendingPathComponent(name)
    }

    private func fileSize(for url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
    }

    private func formattedByteCount(_ size: Int64?) -> String {
        guard let size else { return "—" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    private func buildCompressionSummary() -> String? {
        guard let inputSize, let outputSize else { return nil }
        guard inputSize > 0 else { return nil }
        let ratio = Double(outputSize) / Double(inputSize)
        let percent = (1.0 - ratio) * 100.0
        if percent > 0.1 {
            return String(format: "Saved %.1f%% (%@ → %@)", percent, formattedByteCount(inputSize), formattedByteCount(outputSize))
        }
        return "Output is \(String(format: "%.1f", ratio * 100))% of input."
    }

}

#Preview {
    ContentView()
}

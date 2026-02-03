import Foundation
import ImageIO
import UniformTypeIdentifiers

enum GhostscriptPreset: String, CaseIterable, Identifiable {
    case reallyLossy
    case almostLossless
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .reallyLossy:
            return "Smallest File"
        case .almostLossless:
            return "High Quality"
        case .custom:
            return "Custom"
        }
    }

    var description: String {
        switch self {
        case .reallyLossy:
            return "Aggressive downsampling. Best for quick sharing or previews. Text stays readable, images get softer."
        case .almostLossless:
            return "Light compression that keeps images looking close to the original while still saving space."
        case .custom:
            return "Choose your own image sharpness and JPEG quality."
        }
    }

    var gsValue: String? {
        switch self {
        case .reallyLossy:
            return "/screen"
        case .almostLossless, .custom:
            return nil
        }
    }
}

struct GhostscriptOptions {
    var preset: GhostscriptPreset
    var dpi: Int
    var jpegQuality: Int
}

enum GhostscriptError: LocalizedError {
    case missingBinary
    case missingResources
    case processFailed(code: Int32, reason: Process.TerminationReason, output: String)

    var errorDescription: String? {
        switch self {
        case .missingBinary:
            return "Ghostscript binary not found in app bundle. Run scripts/vendor_ghostscript.sh and rebuild."
        case .missingResources:
            return "Ghostscript resources not found. Ensure the share/ghostscript directory is bundled."
        case .processFailed(let code, let reason, let output):
            if reason == .uncaughtSignal {
                let signalName = code == 9 ? "SIGKILL" : "signal \(code)"
                return "Ghostscript was terminated by \(signalName)."
            }
            if output.isEmpty {
                return "Ghostscript failed with exit code \(code)."
            }
            return "Ghostscript failed (code \(code)): \(output)"
        }
    }
}

enum GhostscriptService {
    static func compress(input: URL, output: URL, options: GhostscriptOptions, completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let resolved: ResolvedGhostscript
            do {
                resolved = try resolveGhostscript()
            } catch {
                completion(.failure(error))
                return
            }

            var args: [String] = [
                "-dSAFER",
                "-dBATCH",
                "-dNOPAUSE",
                "-dQUIET",
                "-sDEVICE=pdfwrite",
                "-dCompatibilityLevel=1.4",
                "-sOutputFile=\(output.path)"
            ]

            args.append(contentsOf: [
                "-dDetectDuplicateImages=true",
                "-dCompressFonts=true",
                "-dSubsetFonts=true",
                "-dAutoRotatePages=/None"
            ])

            if let resources = resolved.resources {
                for includePath in resources.includePaths {
                    args.append("-I\(includePath)")
                }
                if let fontPath = resources.fontPath {
                    args.append("-sFONTPATH=\(fontPath)")
                }
            }

            if let presetValue = options.preset.gsValue {
                args.append("-dPDFSETTINGS=\(presetValue)")
            } else {
                args.append(contentsOf: [
                    "-dDownsampleColorImages=true",
                    "-dColorImageResolution=\(options.dpi)",
                    "-dColorImageDownsampleType=/Bicubic",
                    "-dColorImageFilter=/DCTEncode",
                    "-dDownsampleGrayImages=true",
                    "-dGrayImageResolution=\(options.dpi)",
                    "-dGrayImageDownsampleType=/Bicubic",
                    "-dGrayImageFilter=/DCTEncode",
                    "-dDownsampleMonoImages=true",
                    "-dMonoImageResolution=\(max(options.dpi, 300))",
                    "-dMonoImageDownsampleType=/Subsample",
                    "-dJPEGQ=\(options.jpegQuality)"
                ])
            }

            args.append(input.path)

            let process = Process()
            process.executableURL = resolved.url
            process.arguments = args

            process.environment = buildEnvironment(resources: resolved.resources)

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            process.terminationHandler = { task in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let outputText = String(data: data, encoding: .utf8) ?? ""
                if task.terminationStatus == 0 {
                    completion(.success(()))
                } else {
                    completion(.failure(GhostscriptError.processFailed(
                        code: task.terminationStatus,
                        reason: task.terminationReason,
                        output: outputText.trimmingCharacters(in: .whitespacesAndNewlines)
                    )))
                }
            }

            do {
                try process.run()
            } catch {
                completion(.failure(error))
            }
        }
    }

    static func rasterize(input: URL, output: URL, dpi: Int, jpegQuality: Int, completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let resolved: ResolvedGhostscript
            do {
                resolved = try resolveGhostscript()
            } catch {
                completion(.failure(error))
                return
            }

            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pdfcompressor-rasterize-\(UUID().uuidString)")
            do {
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            } catch {
                completion(.failure(error))
                return
            }

            let pattern = tempDir.appendingPathComponent("page-%04d.jpg").path
            let jpegArgs: [String] = [
                "-dSAFER",
                "-dBATCH",
                "-dNOPAUSE",
                "-dQUIET",
                "-sDEVICE=jpeg",
                "-dJPEGQ=\(jpegQuality)",
                "-r\(dpi)",
                "-sOutputFile=\(pattern)",
                input.path
            ]

            let env = buildEnvironment(resources: resolved.resources)
            let includeArgs = includePaths(resources: resolved.resources)
            run(gsURL: resolved.url, arguments: includeArgs + jpegArgs, environment: env) { firstResult in
                switch firstResult {
                case .failure(let error):
                    completion(.failure(error))
                case .success:
                    let images = (try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil))
                        ?? []
                    let jpgs = images.filter { $0.pathExtension.lowercased() == "jpg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                    guard !jpgs.isEmpty else {
                        completion(.failure(GhostscriptError.processFailed(code: 1, reason: .exit, output: "Rasterization produced no images.")))
                        return
                    }

                    do {
                        try assemblePDF(from: jpgs, output: output, dpi: dpi)
                        try? FileManager.default.removeItem(at: tempDir)
                        completion(.success(()))
                    } catch {
                        try? FileManager.default.removeItem(at: tempDir)
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    private static func buildEnvironment(resources: ResourcePaths?) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        guard let resources else { return env }
        env["GS_LIB"] = resources.libPaths
        if let fontPath = resources.fontPath {
            env["GS_FONTPATH"] = fontPath
        }
        return env
    }

    private static func includePaths(resources: ResourcePaths?) -> [String] {
        guard let resources else { return [] }
        var args: [String] = []
        for includePath in resources.includePaths {
            args.append("-I\(includePath)")
        }
        if let fontPath = resources.fontPath {
            args.append("-sFONTPATH=\(fontPath)")
        }
        return args
    }

    private static func run(
        gsURL: URL,
        arguments: [String],
        environment: [String: String],
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let process = Process()
        process.executableURL = gsURL
        process.arguments = arguments
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        process.terminationHandler = { task in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let outputText = String(data: data, encoding: .utf8) ?? ""
            if task.terminationStatus == 0 {
                completion(.success(()))
            } else {
                completion(.failure(GhostscriptError.processFailed(
                    code: task.terminationStatus,
                    reason: task.terminationReason,
                    output: outputText.trimmingCharacters(in: .whitespacesAndNewlines)
                )))
            }
        }

        do {
            try process.run()
        } catch {
            completion(.failure(error))
        }
    }

    private static func assemblePDF(from jpgs: [URL], output: URL, dpi: Int) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            output as CFURL,
            UTType.pdf.identifier as CFString,
            jpgs.count,
            nil
        ) else {
            throw GhostscriptError.processFailed(code: 1, reason: .exit, output: "Failed to create PDF destination.")
        }

        for jpg in jpgs {
            guard let source = CGImageSourceCreateWithURL(jpg as CFURL, nil) else {
                throw GhostscriptError.processFailed(code: 1, reason: .exit, output: "Failed to read rasterized image.")
            }
            let properties: [CFString: Any] = [
                kCGImagePropertyDPIWidth: dpi,
                kCGImagePropertyDPIHeight: dpi
            ]
            CGImageDestinationAddImageFromSource(destination, source, 0, properties as CFDictionary)
        }

        if !CGImageDestinationFinalize(destination) {
            throw GhostscriptError.processFailed(code: 1, reason: .exit, output: "Failed to finalize rasterized PDF.")
        }
    }

    private static func resolveGhostscript() throws -> ResolvedGhostscript {
        if let bundled = Bundle.main.url(forResource: "gs", withExtension: nil, subdirectory: "ghostscript") {
            let root = bundled.deletingLastPathComponent()
            guard let resources = resourcePaths(in: root) else {
                throw GhostscriptError.missingResources
            }
            return ResolvedGhostscript(url: bundled, resources: resources)
        }
        if let external = findExecutable(named: "gs") {
            return ResolvedGhostscript(url: external, resources: nil)
        }
        throw GhostscriptError.missingBinary
    }

    private static func findExecutable(named name: String) -> URL? {
        let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for path in envPath.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(path)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private static func resourcePaths(in root: URL) -> ResourcePaths? {
        let fm = FileManager.default
        let share = root.appendingPathComponent("share/ghostscript")
        guard let entries = try? fm.contentsOfDirectory(
            at: share,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let versionDirs = entries.filter { url in
            guard let isDir = try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory else {
                return false
            }
            let name = url.lastPathComponent
            return isDir && name.first?.isNumber == true
        }

        let resourceRoot: URL
        if let versionDir = versionDirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).last {
            resourceRoot = versionDir.resolvingSymlinksInPath()
        } else {
            // Some bundles flatten resources directly under share/ghostscript.
            let candidate = share.appendingPathComponent("Resource")
            guard fm.fileExists(atPath: candidate.path) else {
                return nil
            }
            resourceRoot = share
        }

        let resourceInit = resourceRoot.appendingPathComponent("Resource/Init")
        let resourceFonts = resourceRoot.appendingPathComponent("Resource/Font")
        let legacyFonts = share.appendingPathComponent("fonts")
        let resourceLib = resourceRoot.appendingPathComponent("lib")

        var libPaths = [resourceRoot.path]
        var includePaths = [resourceRoot.path]
        if fm.fileExists(atPath: resourceInit.path) {
            includePaths.append(resourceInit.path)
        }
        if fm.fileExists(atPath: resourceLib.path) {
            libPaths.append(resourceLib.path)
            includePaths.append(resourceLib.path)
        }

        var fontPath: String?
        if fm.fileExists(atPath: resourceFonts.path) {
            fontPath = resourceFonts.path
        } else if fm.fileExists(atPath: legacyFonts.path) {
            fontPath = legacyFonts.path
        }
        if let fontPath {
            libPaths.append(fontPath)
        }

        return ResourcePaths(libPaths: libPaths.joined(separator: ":"), fontPath: fontPath, includePaths: includePaths)
    }
}

private struct ResourcePaths {
    let libPaths: String
    let fontPath: String?
    let includePaths: [String]
}

private struct ResolvedGhostscript {
    let url: URL
    let resources: ResourcePaths?
}

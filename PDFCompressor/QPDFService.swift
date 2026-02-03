import Foundation

struct QPDFOptions {
    var compressionLevel: Int
    var recompressFlate: Bool
    var generateObjectStreams: Bool
    var optimizeImages: Bool

    var arguments: [String] {
        var args: [String] = []

        if generateObjectStreams {
            args.append("--object-streams=generate")
        }

        if recompressFlate {
            args.append("--recompress-flate")
        }

        args.append("--stream-data=compress")
        args.append("--compression-level=\(compressionLevel)")

        if optimizeImages {
            args.append("--optimize-images")
        }

        return args
    }
}

enum QPDFError: LocalizedError {
    case missingBinary
    case processFailed(code: Int32, reason: Process.TerminationReason, output: String)

    var errorDescription: String? {
        switch self {
        case .missingBinary:
            return "qpdf binary not found in app bundle."
        case .processFailed(let code, let reason, let output):
            if reason == .uncaughtSignal {
                let signalName = code == 9 ? "SIGKILL" : "signal \(code)"
                return "qpdf was terminated by \(signalName). This is often due to memory pressure on large PDFs. Try lowering the compression level or disabling Recompress Flate / Optimize images."
            }
            if output.isEmpty {
                return "qpdf failed with exit code \(code)."
            }
            return "qpdf failed (code \(code)): \(output)"
        }
    }
}

enum QPDFService {
    static func compress(input: URL, output: URL, options: QPDFOptions, completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let qpdfURL = Bundle.main.url(forResource: "qpdf", withExtension: nil, subdirectory: "qpdf") else {
                completion(.failure(QPDFError.missingBinary))
                return
            }

            let process = Process()
            process.executableURL = qpdfURL
            process.arguments = options.arguments + ["--", input.path, output.path]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            process.terminationHandler = { task in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let outputText = String(data: data, encoding: .utf8) ?? ""
                if task.terminationStatus == 0 {
                    completion(.success(()))
                } else {
                    completion(.failure(QPDFError.processFailed(code: task.terminationStatus, reason: task.terminationReason, output: outputText.trimmingCharacters(in: .whitespacesAndNewlines))))
                }
            }

            do {
                try process.run()
            } catch {
                completion(.failure(error))
            }
        }
    }
}

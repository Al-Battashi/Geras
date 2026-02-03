import Foundation

enum RasterizeService {
    static func rasterize(
        input: URL,
        output: URL,
        dpi: CGFloat,
        jpegQuality: Int,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        GhostscriptService.rasterize(
            input: input,
            output: output,
            dpi: Int(dpi),
            jpegQuality: jpegQuality,
            completion: completion
        )
    }
}

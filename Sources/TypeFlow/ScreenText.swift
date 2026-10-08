import AppKit
import Vision

/// A pasted screenshot as the message a reply answers: Apple Vision reads its text
/// on-device for the context box, and the image itself goes to the coach (a
/// diagram needs the picture). Never saved beyond the check or logged.
enum ScreenText {
    /// An image on the clipboard: a screenshot (⌃⌘⇧4) or a copied image file.
    static func clipboardImage(_ pb: NSPasteboard = .general) -> CGImage? {
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true,
                                               .urlReadingContentsConformToTypes: ["public.image"]]) as? [URL],
           let url = urls.first, let image = NSImage(contentsOf: url) {
            return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        guard pb.canReadObject(forClasses: [NSImage.self], options: nil),
              let image = NSImage(pasteboard: pb) else { return nil }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// The clipboard holds an image and no text: what a screenshot copy leaves.
    /// (A copied file also carries its name as text, so image files count too.)
    static func clipboardIsImageOnly(_ pb: NSPasteboard = .general) -> Bool {
        let hasFileImage = (pb.readObjects(forClasses: [NSURL.self],
                                           options: [.urlReadingFileURLsOnly: true,
                                                     .urlReadingContentsConformToTypes: ["public.image"]]) ?? []).isEmpty == false
        if hasFileImage { return true }
        return pb.string(forType: .string) == nil && pb.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    /// The first recognition in a newly built binary takes ~65 s while Vision
    /// prepares its model (measured 2026-10-08, M1 Pro; every later call, in any
    /// process of that binary, ~0.5 s). Called once at launch, in the background,
    /// so that cost lands after an install instead of on the first screenshot.
    static func warmUp() {
        Task.detached(priority: .background) {
            guard let tiny = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                       space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
            else { return }
            _ = try? await recognize(tiny)
        }
    }

    /// Recognized lines, top to bottom, English and Spanish.
    static func recognize(_ image: CGImage) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US", "es-ES"]
            request.usesLanguageCorrection = true
            try VNImageRequestHandler(cgImage: upscaled(image)).perform([request])
            let lines = (request.results ?? [])
                // Vision's origin is bottom-left: a higher midY is higher on screen.
                .sorted { a, b in
                    abs(a.boundingBox.midY - b.boundingBox.midY) > 0.005
                        ? a.boundingBox.midY > b.boundingBox.midY
                        : a.boundingBox.minX < b.boundingBox.minX
                }
                .compactMap { $0.topCandidates(1).first?.string }
            return lines.joined(separator: "\n")
        }.value
    }

    /// PNG for the coach, longest side capped at 2000 px: models downscale past
    /// that anyway, and Claude refuses images over 5 MB. Never written anywhere
    /// but the coach's temp file, deleted after the check.
    static func uploadPNG(_ image: CGImage) -> Data? {
        let longest = max(image.width, image.height)
        var out = image
        if longest > 2000 {
            let k = 2000.0 / Double(longest)
            let w = Int(Double(image.width) * k), h = Int(Double(image.height) * k)
            if let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.interpolationQuality = .high
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                out = ctx.makeImage() ?? image
            }
        }
        return NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])
    }

    /// A 1x-display capture (e.g. the 3440×1440 external monitor) has terminal
    /// text too small for Vision: bold lines came back garbled or missing. Doubling
    /// it recovered them; a Retina capture is already big enough.
    private static func upscaled(_ image: CGImage) -> CGImage {
        guard image.width < 2200, image.width > 64 else { return image }
        let w = image.width * 2, h = image.height * 2
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }
}

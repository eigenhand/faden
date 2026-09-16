import UIKit

/// An image the user attached to the next message.
struct ImageAttachment: Identifiable, Equatable {
    let id = UUID()
    let image: UIImage
    /// JPEG bytes, already scaled down for sending.
    let jpeg: Data

    var base64: String { jpeg.base64EncodedString() }
    var mediaType: String { "image/jpeg" }

    /// Both wire formats bill by pixel area and cap the long edge, so a phone photo
    /// is scaled before it is ever encoded — a full-resolution shot would cost a
    /// large share of the context window for no gain in what the model can see.
    static func make(from image: UIImage, maxEdge: CGFloat = 1_400, quality: CGFloat = 0.8) -> ImageAttachment? {
        let scaled = image.scaledDown(maxEdge: maxEdge)
        guard let data = scaled.jpegData(compressionQuality: quality) else { return nil }
        return ImageAttachment(image: scaled, jpeg: data)
    }
}

extension UIImage {
    func scaledDown(maxEdge: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxEdge, longest > 0 else { return normalizedUp() }
        let factor = maxEdge / longest
        let target = CGSize(width: (size.width * factor).rounded(),
                            height: (size.height * factor).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// Redraws so the EXIF orientation is baked in — otherwise a photo taken in
    /// portrait arrives at the model rotated.
    private func normalizedUp() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

import SwiftUI
import UIKit

/// The camera, wrapped for SwiftUI.
///
/// The composer reached the photo library and nothing else. But a good share of the
/// questions worth asking a model about a picture are about something in front of
/// you right now — a label, an error on a screen, a part that broke — and having to
/// leave for the camera app, take the shot and come back is most of the reason not
/// to bother asking at all.
struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss

    /// False in the simulator and on any device without a usable camera.
    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate,
                             UINavigationControllerDelegate {
        private let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.editedImage] as? UIImage ?? info[.originalImage] as? UIImage {
                parent.onImage(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

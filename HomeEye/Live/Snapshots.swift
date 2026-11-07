import Photos
import UIKit

enum Snapshots {
    /// Adds the image to the photo library (add-only access). Returns false if access is
    /// refused or saving fails.
    static func saveToPhotos(_ image: UIImage) async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return false }
        guard let data = image.jpegData(compressionQuality: 0.92) else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }
            return true
        } catch {
            return false
        }
    }
}

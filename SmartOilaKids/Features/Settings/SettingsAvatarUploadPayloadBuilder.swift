import UIKit

struct SettingsAvatarUploadPayload {
    let previewImage: UIImage
    let uploadData: Data
}

enum SettingsAvatarUploadPayloadBuilder {
    static func make(from image: UIImage) -> SettingsAvatarUploadPayload? {
        guard let uploadData = image.jpegData(compressionQuality: 0.85) else {
            return nil
        }

        return SettingsAvatarUploadPayload(previewImage: image, uploadData: uploadData)
    }
}

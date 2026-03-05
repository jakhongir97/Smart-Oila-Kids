import PhotosUI
import SwiftUI
import UIKit

struct SettingsAvatarUploadPayload {
    let previewImage: UIImage
    let uploadData: Data
}

enum SettingsAvatarUploadPayloadBuilder {
    static func make(from item: PhotosPickerItem) async -> SettingsAvatarUploadPayload? {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            return nil
        }

        let uploadData = image.jpegData(compressionQuality: 0.85) ?? data
        return SettingsAvatarUploadPayload(previewImage: image, uploadData: uploadData)
    }
}

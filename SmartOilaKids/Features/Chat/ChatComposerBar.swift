import SwiftUI
import UIKit

struct ChatComposerBar: View {
    @Binding var text: String
    @Binding var showAttachmentPicker: Bool
    let selectedAttachmentsCount: Int
    let queuedMessagesCount: Int
    let sendStatusText: String?
    let isLoadingAttachments: Bool
    let canSend: Bool
    let isSending: Bool
    let bottomInset: CGFloat
    let sidePadding: CGFloat
    let compact: Bool
    let focus: FocusState<Bool>.Binding
    let onRetryQueued: () -> Void
    let onSend: () -> Void

    private let composerForeground = Color(red: 66 / 255, green: 66 / 255, blue: 66 / 255)

    var body: some View {
        VStack(spacing: 6) {
            if queuedMessagesCount > 0 {
                HStack(spacing: 10) {
                    Text(L10n.tr("chat.retry_pending", queuedMessagesCount))
                        .font(AppTypography.unbounded(11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(2)

                    Spacer(minLength: 8)

                    Button {
                        AppHaptics.tap()
                        onRetryQueued()
                    } label: {
                        Text(L10n.tr("chat.retry"))
                            .font(AppTypography.unbounded(11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(AppColors.primaryPurple)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 2)
            }

            if let sendStatusText, !sendStatusText.isEmpty {
                Text(sendStatusText)
                    .font(AppTypography.unbounded(11, weight: .regular))
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 2)
            } else if isLoadingAttachments {
                Text(L10n.tr("chat.attachments_loading"))
                    .font(AppTypography.unbounded(11, weight: .regular))
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 2)
            } else if selectedAttachmentsCount > 0 {
                Text(L10n.tr("chat.attachments_count", selectedAttachmentsCount))
                    .font(AppTypography.unbounded(11, weight: .regular))
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 2)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(AppColors.neutral700)
                    .frame(height: 45)

                HStack(spacing: 12) {
                    Button {
                        AppHaptics.tap()
                        showAttachmentPicker = true
                    } label: {
                        Image(systemName: "paperclip")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(composerForeground.opacity(0.82))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .topTrailing) {
                        if selectedAttachmentsCount > 0 {
                            ZStack {
                                Circle()
                                    .fill(AppColors.dangerRed)
                                    .frame(width: 14, height: 14)
                                Text("\(selectedAttachmentsCount)")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                            .offset(x: 6, y: -6)
                        }
                    }

                    TextField(L10n.tr("chat.message_placeholder"), text: $text)
                        .font(AppTypography.unbounded(14, weight: .medium))
                        .foregroundStyle(composerForeground)
                        .tint(composerForeground)
                        .focused(focus)
                        .textInputAutocapitalization(.sentences)
                        .submitLabel(.send)
                        .onSubmit {
                            onSend()
                        }

                    Spacer(minLength: 0)

                    Button {
                        onSend()
                    } label: {
                        if isSending {
                            ProgressView()
                                .tint(AppColors.primaryPurple)
                        } else if UIImage(named: "IconSend") != nil {
                            Image("IconSend")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 20, height: 20)
                        } else {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(composerForeground)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend || isLoadingAttachments)
                    .accessibilityLabel(L10n.tr("chat.send"))
                }
                .padding(.horizontal, 20)
                .frame(height: 45)
            }
        }
        .padding(.horizontal, sidePadding)
        .padding(.top, compact ? 6 : 8)
        .padding(.bottom, bottomInset + (compact ? 8 : 10))
        .background(AppColors.neutral800)
    }
}

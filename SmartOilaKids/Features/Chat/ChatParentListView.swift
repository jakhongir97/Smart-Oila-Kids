import SwiftUI
import UIKit

struct ParentChatRow {
    let id: String
    let name: String
    let preview: String
    let unreadCount: Int
}

struct ChatParentListView: View {
    let rows: [ParentChatRow]
    let sidePadding: CGFloat
    let compact: Bool
    let onOpen: (ParentChatRow) -> Void
    let onRefresh: () async -> Void

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 10) {
                ForEach(rows, id: \.id) { row in
                    Button {
                        AppHaptics.tap()
                        onOpen(row)
                    } label: {
                        chatRow(name: row.name, preview: row.preview, unreadCount: row.unreadCount)
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilityLabel(for: row))
                    .accessibilityHint(L10n.tr("chat.open_parent_chat_hint"))
                }

                Spacer()
            }
            .padding(.horizontal, sidePadding)
            .padding(.top, compact ? 18 : 30)
            .padding(.bottom, 16)
        }
        .refreshable {
            await onRefresh()
        }
    }

    private func chatRow(name: String, preview: String, unreadCount: Int) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.gray.opacity(0.35))
                .frame(width: 50, height: 50)
                .overlay {
                    if UIImage(named: "UserAvatarGlyph") != nil {
                        Image("UserAvatarGlyph")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 30, height: 30)
                    } else {
                        Image(systemName: "person.fill")
                            .foregroundStyle(AppColors.textSecondary)
                    }
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(AppTypography.unbounded(16, weight: .semibold))
                    .foregroundStyle(AppColors.black)
                    .lineLimit(2)

                Text(preview)
                    .font(AppTypography.unbounded(12, weight: .regular))
                    .foregroundStyle(AppColors.black)
                    .lineLimit(2)
            }

            Spacer()

            if unreadCount > 0 {
                Text("\(min(99, unreadCount))")
                    .font(AppTypography.unbounded(10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .frame(minWidth: 22, minHeight: 22)
                    .background(AppColors.primaryPurple)
                    .clipShape(Capsule())
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 15)
        .frame(minHeight: 80)
        .background(AppColors.white)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func accessibilityLabel(for row: ParentChatRow) -> String {
        if row.unreadCount > 0 {
            return "\(row.name). \(row.preview). \(L10n.tr("chat.unread_count", row.unreadCount))"
        }
        return "\(row.name). \(row.preview)"
    }
}

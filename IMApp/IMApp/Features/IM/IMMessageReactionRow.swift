import IMClientKit
import SwiftUI

struct IMMessageReactionRow: View {
    let reactions: [IMMessageReaction]
    let currentUserID: UUID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(reactions, id: \.emoji) { reaction in
                    let didReact = currentUserID.map(reaction.actorUserIDs.contains) ?? false
                    HStack(spacing: 4) {
                        Text(reaction.emoji)
                        Text("\(reaction.actorUserIDs.count)")
                            .font(.caption.weight(.semibold))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(didReact ? Color.accentColor.opacity(0.18) : Color(.tertiarySystemGroupedBackground))
                    )
                }
            }
        }
    }
}

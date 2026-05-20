import SwiftUI
import IMClientKit

extension IMConversationDetailView {
    @ToolbarContentBuilder
    var detailToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                isPresentingBatchSender = true
            } label: {
                Image(systemName: "timer.circle")
            }
            .disabled(!canSendMessages)
            .accessibilityLabel("批量发送测试消息")
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button {
                isPresentingSearch = true
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .accessibilityLabel("搜索会话内消息")
        }

        if conversation?.kind == .group {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if canRenameConversation {
                        Button("修改群名") {
                            isPresentingRenameGroup = true
                        }
                    }

                    if canRenameConversation {
                        Button("编辑群资料") {
                            isPresentingEditMetadata = true
                        }
                    }

                    if canRenameConversation {
                        Button("邀请链接") {
                            isPresentingInvites = true
                        }
                    }

                    Button("我的群昵称") {
                        isPresentingMemberNickname = true
                    }

                    if canAddMembers {
                        Button("添加成员") {
                            isPresentingAddMembers = true
                        }
                    }

                    if canManageMembers {
                        Button("管理成员") {
                            isPresentingManageMembers = true
                        }
                    }

                    Button("退出会话", role: .destructive) {
                        isPresentingLeaveConfirmation = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button(conversation?.isPinned == true ? "取消置顶" : "置顶会话") {
                    Task {
                        _ = await runtimeStore.updateConversationPreferences(
                            conversationID,
                            isPinned: !(conversation?.isPinned ?? false)
                        )
                    }
                }

                Button(conversation?.isMuted == true ? "取消免打扰" : "免打扰") {
                    Task {
                        _ = await runtimeStore.updateConversationPreferences(
                            conversationID,
                            isMuted: !(conversation?.isMuted ?? false)
                        )
                    }
                }

                if let peer = directPeer {
                    if isDirectPeerBlocked {
                        Button("解除拉黑") {
                            Task {
                                _ = await runtimeStore.unblockUser(peer.id)
                            }
                        }
                    } else {
                        Button("拉黑对方", role: .destructive) {
                            Task {
                                _ = await runtimeStore.blockUser(peer.id)
                            }
                        }
                    }

                    Button("举报对方", role: .destructive) {
                        Task {
                            _ = await runtimeStore.reportUser(peer.id, conversationID: conversationID)
                        }
                    }
                }

                Button("清空聊天记录", role: .destructive) {
                    destructiveAction = .clear
                }

                Button("删除会话", role: .destructive) {
                    destructiveAction = .delete
                }
            } label: {
                Image(systemName: "bell.slash.circle")
            }
        }
    }
}

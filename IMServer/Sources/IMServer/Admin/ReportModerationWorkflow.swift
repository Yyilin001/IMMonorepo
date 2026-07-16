import Vapor

enum ReportModerationWorkflow {
    struct Transition: Sendable {
        let previousStatus: String
        let status: String
        let resolutionCategory: String?
        let handledNote: String?
    }

    private static let terminalStatuses: Set<String> = ["resolved", "rejected"]
    private static let resolutionCategories: Set<String> = [
        "action_taken",
        "duplicate",
        "escalated",
        "no_violation",
        "other"
    ]

    static func transition(
        from previousStatus: String,
        requestedStatus: String,
        resolutionCategory: String?,
        handledNote: String?
    ) throws -> Transition {
        let previous = normalizedStatus(previousStatus)
        let status = normalizedStatus(requestedStatus)
        guard allowedTransitions[previous]?.contains(status) == true else {
            throw Abort(.conflict, reason: "举报当前状态不允许执行该转换。")
        }

        let note = try normalizedNote(handledNote)
        let category = normalizedCategory(resolutionCategory)
        if terminalStatuses.contains(status) {
            guard let category, resolutionCategories.contains(category) else {
                throw Abort(.badRequest, reason: "完成举报处理时必须提供有效的处理分类。")
            }
            guard note != nil else {
                throw Abort(.badRequest, reason: "完成举报处理时必须提供处理说明。")
            }
            return Transition(
                previousStatus: previous,
                status: status,
                resolutionCategory: category,
                handledNote: note
            )
        }

        guard category == nil else {
            throw Abort(.badRequest, reason: "处理中状态不允许设置处理分类。")
        }
        return Transition(
            previousStatus: previous,
            status: status,
            resolutionCategory: nil,
            handledNote: note
        )
    }

    private static let allowedTransitions: [String: Set<String>] = [
        "pending": ["reviewing", "resolved", "rejected"],
        "reviewing": ["resolved", "rejected"]
    ]

    private static func normalizedStatus(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalizedCategory(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfEmpty
    }

    private static func normalizedNote(_ value: String?) throws -> String? {
        guard let note = value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            return nil
        }
        guard note.count <= 500 else {
            throw Abort(.badRequest, reason: "处理说明不能超过 500 个字符。")
        }
        return note
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

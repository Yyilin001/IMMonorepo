@testable import IMServer
import Fluent
import Vapor
import VaporTesting
import Testing

extension IMServerTests {
    private var adminSecret: String {
        "admin-secret-0123456789abcdef"
    }

    @Test("Admin API requires configured admin secret")
    func adminAPIRequiresConfiguredSecret() async throws {
        let originalSecret = Environment.get("IM_ADMIN_SHARED_SECRET")
        defer { restoreEnvironment("IM_ADMIN_SHARED_SECRET", to: originalSecret) }
        setenv("IM_ADMIN_SHARED_SECRET", adminSecret, 1)

        try await withApp(configure: configure) { app in
            try await app.testing().test(.GET, "admin/api/overview", afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })

            try await app.testing().test(.GET, "admin/api/overview", beforeRequest: { req in
                req.headers.add(name: "X-IM-Admin-Secret", value: adminSecret)
                req.headers.add(name: "X-IM-Admin-Actor", value: "tester")
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.content.decode(AdminOverviewResponse.self)
                #expect(payload.users.total >= 1)
            })
        }
    }

    @Test("Admin can disable user, revoke sessions, and audit action")
    func adminCanDisableUserAndAuditAction() async throws {
        let originalSecret = Environment.get("IM_ADMIN_SHARED_SECRET")
        defer { restoreEnvironment("IM_ADMIN_SHARED_SECRET", to: originalSecret) }
        setenv("IM_ADMIN_SHARED_SECRET", adminSecret, 1)

        try await withApp(configure: configure) { app in
            var accessToken = ""
            try await app.testing().test(.POST, "api/auth/login", beforeRequest: { req in
                try req.content.encode(loginRequest)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                accessToken = try res.content.decode(AuthResponse.self).accessToken
            })

            let existingUser = try await user(email: loginRequest.email, on: app)
            let userID = try existingUser.requireID()

            try await app.testing().test(.PATCH, "admin/api/users/\(userID.uuidString)/status", beforeRequest: { req in
                req.headers.add(name: "X-IM-Admin-Secret", value: adminSecret)
                req.headers.add(name: "X-IM-Admin-Actor", value: "tester")
                try req.content.encode(AdminUserStatusUpdateRequest(status: "disabled", note: "test disable"))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.content.decode(AdminUserResponse.self)
                #expect(payload.status == UserStatus.disabled.rawValue)
            })

            let updatedUser = try await user(email: loginRequest.email, on: app)
            #expect(updatedUser.status == UserStatus.disabled.rawValue)

            let activeSessionCount = try await AuthSession.query(on: app.db)
                .filter(\.$user.$id == userID)
                .filter(\.$revokedAt == nil)
                .count()
            #expect(activeSessionCount == 0)

            try await app.testing().test(.GET, "api/me", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })

            try await app.testing().test(.GET, "admin/api/audit-events", beforeRequest: { req in
                req.headers.add(name: "X-IM-Admin-Secret", value: adminSecret)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.content.decode(AdminAuditEventPageResponse.self)
                #expect(payload.items.contains(where: { $0.action == "user.status.update" && $0.targetID == userID.uuidString }))
            })
        }
    }

    @Test("Admin can process reports and audit action")
    func adminCanProcessReportsAndAuditAction() async throws {
        let originalSecret = Environment.get("IM_ADMIN_SHARED_SECRET")
        defer { restoreEnvironment("IM_ADMIN_SHARED_SECRET", to: originalSecret) }
        setenv("IM_ADMIN_SHARED_SECRET", adminSecret, 1)

        try await withApp(configure: configure) { app in
            var accessToken = ""
            try await app.testing().test(.POST, "api/auth/login", beforeRequest: { req in
                try req.content.encode(loginRequest)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                accessToken = try res.content.decode(AuthResponse.self).accessToken
            })

            var reportID: UUID?
            try await app.testing().test(.POST, "api/reports", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: accessToken)
                try req.content.encode(ReportCreateRequest(
                    targetType: "user",
                    targetID: UUID().uuidString,
                    conversationID: nil,
                    messageID: nil,
                    reason: "spam",
                    detail: "test report"
                ))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                reportID = try res.content.decode(ReportResponse.self).id
            })

            let id = try #require(reportID)
            try await app.testing().test(.PATCH, "admin/api/reports/\(id.uuidString)", beforeRequest: { req in
                req.headers.add(name: "X-IM-Admin-Secret", value: adminSecret)
                req.headers.add(name: "X-IM-Admin-Actor", value: "tester")
                try req.content.encode(ReportUpdateRequest(status: "resolved", handledNote: "handled"))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.content.decode(ReportResponse.self)
                #expect(payload.status == "resolved")
                #expect(payload.handledNote == "handled")
            })

            try await app.testing().test(.GET, "admin/api/reports?status=resolved", beforeRequest: { req in
                req.headers.add(name: "X-IM-Admin-Secret", value: adminSecret)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.content.decode(ReportPageResponse.self)
                #expect(payload.items.contains(where: { $0.id == id }))
            })

            let auditCount = try await AdminAuditEvent.query(on: app.db)
                .filter(\.$action == "report.status.update")
                .count()
            #expect(auditCount >= 1)
        }
    }
}

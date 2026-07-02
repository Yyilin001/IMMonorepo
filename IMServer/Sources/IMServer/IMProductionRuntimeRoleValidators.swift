import Vapor

enum IMGatewayProductionValidator {
    static func validate(app: Application) throws {
        try IMProductionRuntimeValidationSupport.validateGatewayCommandIngressConfiguration(app)
        try IMProductionRuntimeValidationSupport.validateCommandOwnerRoutingConfiguration(
            app,
            requiresLocalNodeID: false
        )
        try IMProductionRuntimeValidationSupport.validateTCPTransportExposure(app)
        try IMProductionRuntimeValidationSupport.validateGatewayRealtimeFanoutProtection(app)
        try IMProductionRuntimeValidationSupport.validateGatewayRelayBodyLimitConfiguration(app)
    }
}

enum IMCommandAPIProductionValidator {
    static func validate(app: Application) throws {
        try IMProductionRuntimeValidationSupport.validateConversationShardConfiguration(app)
        try IMProductionRuntimeValidationSupport.validateGatewayRelayConfiguration(app)
        try IMProductionRuntimeValidationSupport.validateKafkaProducerConfiguration(app)
        try IMProductionRuntimeValidationSupport.validateProductionMediaStorageConfiguration(app)
        try IMProductionRuntimeValidationSupport.validateHotConversationProtectionConfiguration(app)
        try IMProductionRuntimeValidationSupport.validateSequenceAllocationConfiguration(app)
        try IMProductionRuntimeValidationSupport.validateMessageWriteBatchConfiguration(app)
        try IMProductionRuntimeValidationSupport.validateGroupMemberLimitConfiguration(app)
        try IMProductionRuntimeValidationSupport.validateTimelineReadProtectionConfiguration(app)
        try IMProductionRuntimeValidationSupport.validateTimelineSinceCacheInvalidationConfiguration(app)
        try IMProductionRuntimeValidationSupport.validateAdminAPIConfiguration(app)
        try IMProductionRuntimeValidationSupport.validateCommandOwnerRoutingConfiguration(
            app,
            requiresLocalNodeID: true
        )
    }
}

enum IMQueryAPIProductionValidator {
    static func validate(app: Application) throws {
        try IMProductionRuntimeValidationSupport.validateConversationShardConfiguration(app)
        try IMProductionRuntimeValidationSupport.validateSummaryReadModelReadConfiguration(app)
        try IMProductionRuntimeValidationSupport.validateSearchConfiguration(app)
        try IMProductionRuntimeValidationSupport.validateTimelineReadProtectionConfiguration(app)
        try IMProductionRuntimeValidationSupport.validateTimelineSinceCacheInvalidationConfiguration(app)
    }
}

enum IMOutboxRelayProductionValidator {
    static func validate(app: Application) throws {
        try IMProductionRuntimeValidationSupport.validateConversationShardConfiguration(app)
        try IMProductionRuntimeValidationSupport.validateKafkaProducerConfiguration(app)
    }
}

enum IMStreamConsumerProductionValidator {
    static func validate(app: Application) throws {
        try IMProductionRuntimeValidationSupport.validateConversationShardConfiguration(app)
        try IMProductionRuntimeValidationSupport.validateKafkaConsumerConfiguration(app)
        try IMProductionRuntimeValidationSupport.validateStreamConsumerDeploymentIsolation(app)
        try IMProductionRuntimeValidationSupport.validateStreamConsumerBatchingConfiguration(app)
        try IMProductionRuntimeValidationSupport.validateStreamConsumerLargeGroupProtection(app)
        if app.streamConsumerConfiguration.isEnabled("domain-delivery-consumer")
            || app.streamConsumerConfiguration.isEnabled("realtime-delivery-consumer") {
            try IMProductionRuntimeValidationSupport.validateGatewayRelayConfiguration(app)
        }
        try IMProductionRuntimeValidationSupport.validateLargeGroupRealtimeDeliveryPath(app)
        try IMProductionRuntimeValidationSupport.validateTimelineSinceCacheInvalidationConfiguration(app)
        try IMProductionRuntimeValidationSupport.validateSummaryReadModelWriteConfiguration(app)
        try IMProductionRuntimeValidationSupport.validateSearchConfiguration(app)
    }
}

enum IMOpsProductionValidator {
    static func validate(app: Application) throws {
        try IMProductionRuntimeValidationSupport.validateConversationShardConfiguration(app)
        try IMProductionRuntimeValidationSupport.validateKafkaProducerConfiguration(app)
        try IMProductionRuntimeValidationSupport.validateSummaryReadModelWriteConfiguration(app)
        try IMProductionRuntimeValidationSupport.validateSummaryReadModelReadConfiguration(app)
        try IMProductionRuntimeValidationSupport.validateSearchConfiguration(app)
    }
}

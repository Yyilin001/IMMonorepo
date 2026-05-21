import Vapor

private struct IMSequenceAllocationConfigurationStorageKey: StorageKey {
    typealias Value = IMSequenceAllocationConfiguration
}

private struct IMCommandOwnerRoutingConfigurationStorageKey: StorageKey {
    typealias Value = IMCommandOwnerRoutingConfiguration
}

private struct IMConversationMemberCacheConfigurationStorageKey: StorageKey {
    typealias Value = IMConversationMemberCacheConfiguration
}

private struct IMMessageWriteBatchConfigurationStorageKey: StorageKey {
    typealias Value = IMMessageWriteBatchConfiguration
}

private struct IMSequenceBlockAllocatorStorageKey: StorageKey {
    typealias Value = IMSequenceBlockAllocator
}

private struct IMMessageWriteBatcherStorageKey: StorageKey {
    typealias Value = IMMessageWriteBatcher
}

private struct IMConversationWriteCoordinatorStorageKey: StorageKey {
    typealias Value = IMConversationWriteCoordinator
}

private struct IMConversationMemberCacheStorageKey: StorageKey {
    typealias Value = IMConversationMemberCache
}

private struct IMDirectConversationPairCacheStorageKey: StorageKey {
    typealias Value = IMDirectConversationPairCache
}

private struct IMMessageWriteMetricsStorageKey: StorageKey {
    typealias Value = IMMessageWriteMetrics
}

extension Application {
    var sequenceAllocationConfiguration: IMSequenceAllocationConfiguration {
        get {
            if let configuration = storage[IMSequenceAllocationConfigurationStorageKey.self] {
                return configuration
            }
            let configuration = IMSequenceAllocationConfiguration.load(from: environment)
            storage[IMSequenceAllocationConfigurationStorageKey.self] = configuration
            return configuration
        }
        set { storage[IMSequenceAllocationConfigurationStorageKey.self] = newValue }
    }

    var commandOwnerRoutingConfiguration: IMCommandOwnerRoutingConfiguration {
        get {
            if let configuration = storage[IMCommandOwnerRoutingConfigurationStorageKey.self] {
                return configuration
            }
            let configuration = IMCommandOwnerRoutingConfiguration.load(from: environment)
            storage[IMCommandOwnerRoutingConfigurationStorageKey.self] = configuration
            return configuration
        }
        set { storage[IMCommandOwnerRoutingConfigurationStorageKey.self] = newValue }
    }

    var conversationMemberCacheConfiguration: IMConversationMemberCacheConfiguration {
        get {
            if let configuration = storage[IMConversationMemberCacheConfigurationStorageKey.self] {
                return configuration
            }
            let configuration = IMConversationMemberCacheConfiguration.load(from: environment)
            storage[IMConversationMemberCacheConfigurationStorageKey.self] = configuration
            return configuration
        }
        set { storage[IMConversationMemberCacheConfigurationStorageKey.self] = newValue }
    }

    var messageWriteBatchConfiguration: IMMessageWriteBatchConfiguration {
        get {
            if let configuration = storage[IMMessageWriteBatchConfigurationStorageKey.self] {
                return configuration
            }
            let configuration = IMMessageWriteBatchConfiguration.load(from: environment)
            storage[IMMessageWriteBatchConfigurationStorageKey.self] = configuration
            return configuration
        }
        set { storage[IMMessageWriteBatchConfigurationStorageKey.self] = newValue }
    }

    var sequenceBlockAllocator: IMSequenceBlockAllocator {
        get {
            if let allocator = storage[IMSequenceBlockAllocatorStorageKey.self] {
                return allocator
            }
            let allocator = IMSequenceBlockAllocator()
            storage[IMSequenceBlockAllocatorStorageKey.self] = allocator
            return allocator
        }
        set { storage[IMSequenceBlockAllocatorStorageKey.self] = newValue }
    }

    var messageWriteBatcher: IMMessageWriteBatcher {
        get {
            if let batcher = storage[IMMessageWriteBatcherStorageKey.self] {
                return batcher
            }
            let batcher = IMMessageWriteBatcher()
            storage[IMMessageWriteBatcherStorageKey.self] = batcher
            return batcher
        }
        set { storage[IMMessageWriteBatcherStorageKey.self] = newValue }
    }

    var conversationWriteCoordinator: IMConversationWriteCoordinator {
        get {
            if let coordinator = storage[IMConversationWriteCoordinatorStorageKey.self] {
                return coordinator
            }
            let coordinator = IMConversationWriteCoordinator()
            storage[IMConversationWriteCoordinatorStorageKey.self] = coordinator
            return coordinator
        }
        set { storage[IMConversationWriteCoordinatorStorageKey.self] = newValue }
    }

    var conversationMemberCache: IMConversationMemberCache {
        get {
            if let cache = storage[IMConversationMemberCacheStorageKey.self] {
                return cache
            }
            let cache = IMConversationMemberCache()
            storage[IMConversationMemberCacheStorageKey.self] = cache
            return cache
        }
        set { storage[IMConversationMemberCacheStorageKey.self] = newValue }
    }

    var directConversationPairCache: IMDirectConversationPairCache {
        get {
            if let cache = storage[IMDirectConversationPairCacheStorageKey.self] {
                return cache
            }
            let cache = IMDirectConversationPairCache()
            storage[IMDirectConversationPairCacheStorageKey.self] = cache
            return cache
        }
        set { storage[IMDirectConversationPairCacheStorageKey.self] = newValue }
    }

    var messageWriteMetrics: IMMessageWriteMetrics {
        get {
            if let metrics = storage[IMMessageWriteMetricsStorageKey.self] {
                return metrics
            }
            let metrics = IMMessageWriteMetrics()
            storage[IMMessageWriteMetricsStorageKey.self] = metrics
            return metrics
        }
        set { storage[IMMessageWriteMetricsStorageKey.self] = newValue }
    }
}

import IMV2ServerApplication
import IMV2ServerContracts
/// PostgreSQL stores already implement the atomic operation and recovery contract.
/// Conformance changes only their dependency surface; it adds no transaction.
extension PostgresV2DirectMessagingStore: V2DirectRoomBootstrapExecuting {}
extension PostgresV2GroupMessagingStore: V2GroupRoomBootstrapExecuting {}

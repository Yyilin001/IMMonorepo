import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum V2ResourceDirectoryIO {
    static func synchronize(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw V2ResourceStorageError.unavailable }
        defer {
            #if canImport(Darwin)
            _ = Darwin.close(descriptor)
            #else
            _ = Glibc.close(descriptor)
            #endif
        }
        guard fsync(descriptor) == 0 else { throw V2ResourceStorageError.unavailable }
    }
}

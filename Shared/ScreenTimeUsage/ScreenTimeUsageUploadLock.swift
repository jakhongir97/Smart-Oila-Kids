import Foundation
import os

/// One `PUT /device/apps/usage/daily` on the wire at a time, ACROSS the two processes that send it.
///
/// The backend asked for it, and the reason is concrete: each day in the body REPLACES the
/// server's copy, so an older body landing after a newer one lowers today's figure — which can
/// lift a limit the child had already spent. The app's `isUploadingUsage` flag only orders the
/// app's own requests; the monitor extension sends from another process, usually within the same
/// second (it records a step, posts the Darwin notification the app uploads on, then uploads
/// itself). This is a `flock` on a file in the App Group container: whoever holds it sends,
/// whoever does not waits or skips. The kernel releases it if the holder dies mid-request.
final class ScreenTimeUsageUploadLock {
    static let fileName = "usage-upload.lock"

    /// The App Group container — the one directory both processes can open.
    static func defaultDirectory(groupIdentifier: String = ScreenTimeUsageAppGroup.identifier) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)
    }

    /// Try once. Nil when the directory is unavailable or the lock is held.
    static func tryAcquire(directory: URL? = defaultDirectory()) -> ScreenTimeUsageUploadLock? {
        guard let directory else { return nil }
        let path = directory.appendingPathComponent(fileName).path
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        return ScreenTimeUsageUploadLock(descriptor: descriptor)
    }

    /// Wait up to `timeout` for the lock, sleeping the calling thread between tries. For the
    /// extension, whose callback is synchronous anyway. With no container at all there is nothing
    /// to lock on — the caller proceeds unlocked rather than never sending.
    static func acquire(timeout: TimeInterval, pollInterval: TimeInterval = 0.25) -> ScreenTimeUsageUploadLock? {
        guard let directory = defaultDirectory() else { return ScreenTimeUsageUploadLock(descriptor: -1) }
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let lock = tryAcquire(directory: directory) { return lock }
            Thread.sleep(forTimeInterval: pollInterval)
        } while Date() < deadline
        return nil
    }

    /// The same wait without blocking the actor — for the app.
    static func acquire(timeout: TimeInterval, pollInterval: TimeInterval = 0.25) async -> ScreenTimeUsageUploadLock? {
        guard let directory = defaultDirectory() else { return ScreenTimeUsageUploadLock(descriptor: -1) }
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let lock = tryAcquire(directory: directory) { return lock }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        } while Date() < deadline
        return nil
    }

    func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit { release() }

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    private var descriptor: Int32
}

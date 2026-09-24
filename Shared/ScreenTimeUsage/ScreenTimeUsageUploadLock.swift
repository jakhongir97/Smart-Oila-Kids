import Foundation

/// One `PUT /device/apps/usage/daily` on the wire at a time, ACROSS the two processes that send it.
///
/// The backend asked for it, and the reason is concrete: each day in the body REPLACES the
/// server's copy, so an older body landing after a newer one lowers today's figure — which can
/// lift a limit the child had already spent. The app's `isUploadingUsage` flag only orders the
/// app's own requests; the monitor extension sends from another process, usually within the same
/// second (it records a step, posts the Darwin notification the app uploads on, then uploads
/// itself). Whoever holds this sends; whoever does not waits or skips.
///
/// A LEASE, NOT A HELD LOCK (build 28). Builds 23–27 held a `flock` on a file in the App Group
/// container for the whole request, and iOS kills a process that is suspended while it holds a
/// file lock in a shared container: RUNNINGBOARD 0xDEAD10CC, the "Bolajon360 crashed" of
/// 2026-09-22 (build 25) and 2026-09-24 (build 26), every thread idle waiting on the network.
/// Nothing a process does can promise it is not suspended in the middle of a request — iOS can
/// refuse background time or end it, and build 27 still took the lock before it had asked for any
/// — so the only safe lock is one that is not held while anything slow happens.
///
/// The file therefore holds a RECORD — who is sending, and until when — and the `flock` guards
/// nothing but the read-modify-write of that record: open, lock, read, write, unlock, close, in one
/// synchronous call with no await, no network and no sleep inside, let go before `claim` or
/// `release` returns. A process frozen or killed mid-request holds no kernel lock at all; its
/// record simply runs out at `deadline`. Every holder cancels its own request before its deadline
/// (`releaseMargin`), so a record that has run out has no body of its own left on the wire.
final class ScreenTimeUsageUploadLock {
    /// A new name, not build 27's `usage-upload.lock`: that file was a bare lock with no record in it.
    static let fileName = "usage-upload.lease"

    /// Who holds a lease. In the record, so a log line can say who a busy lease belongs to.
    enum Owner: String {
        case app
        case monitorExtension = "ext"
    }

    enum Claim {
        /// This process sends. Call `release()` when the request is over; it also runs on deinit.
        case claimed(ScreenTimeUsageUploadLock)
        /// Another sender's lease is live for `remaining` more seconds.
        case busy(holder: String, remaining: TimeInterval)
        /// The record could not be opened at all (the `errno`) — before the first unlock, for one.
        /// Nothing to wait for: waiting was how build 27 spent its whole timeout on a file it could
        /// never open, and then logged it as "busy".
        case unavailable(errno: Int32)
    }

    /// How long before its lease runs out a holder must have cancelled its request. It covers the
    /// hop from the cancel back to `release()`, and the few milliseconds a cancelled request takes
    /// to stop.
    static let releaseMargin: TimeInterval = 5

    /// The longest lease anyone may ask for. A record claiming more is not a lease: the clock it was
    /// written on is gone (`CLOCK_MONOTONIC` restarts at boot) or the file is garbage — either way
    /// nobody is sending behind it.
    static let maximumDuration: TimeInterval = 60

    /// The App Group container — the one directory both processes can open.
    static func defaultDirectory(groupIdentifier: String = ScreenTimeUsageAppGroup.identifier) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)
    }

    /// Looked up once per process: the app polls the lease every 250 ms while another holder sends,
    /// and the container's location does not change under a running process.
    static let sharedDirectory: URL? = defaultDirectory()

    /// The one clock both processes share: system-wide, counting through sleep, and out of the
    /// child's reach — the wall clock is theirs to move, and a lease read on it could be made to
    /// last for hours or never to hold.
    static func monotonicNow() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_MONOTONIC)
    }

    /// Try once to become the sender for `duration` seconds.
    ///
    /// With no container at all there is nothing to coordinate on — the caller proceeds unguarded
    /// rather than never sending (the lease it gets releases nothing).
    static func claim(
        owner: Owner,
        duration: TimeInterval,
        directory: URL? = sharedDirectory,
        now: () -> UInt64 = monotonicNow,
        processID: Int32 = getpid()
    ) -> Claim {
        guard let directory else {
            return .claimed(ScreenTimeUsageUploadLock(path: nil, token: UUID().uuidString))
        }
        let path = directory.appendingPathComponent(fileName).path
        let token = UUID().uuidString
        let clamped = min(max(duration, 0), maximumDuration)
        let result: Result<Claim, AccessFailure> = withRecord(atPath: path) { existing in
            let at = now()
            if let existing, isLive(existing, now: at, claimant: owner, processID: processID) {
                let remaining = TimeInterval(existing.deadline - at) / 1_000_000_000
                return (.busy(holder: existing.owner, remaining: remaining), .keep)
            }
            let record = Record(
                owner: owner.rawValue,
                processID: processID,
                token: token,
                deadline: at + UInt64(clamped * 1_000_000_000)
            )
            return (.claimed(ScreenTimeUsageUploadLock(path: path, token: token)), .store(record))
        }
        switch result {
        case .success(let claim):
            return claim
        case .failure(.unavailable(let code)):
            return .unavailable(errno: code)
        case .failure(.contended):
            // Another process is inside its few-microsecond read-modify-write right now: a holder
            // in all but name. The caller's next try finds out which.
            return .busy(holder: "?", remaining: 0)
        }
    }

    /// Whether `record` keeps `claimant` out at `now`. Pure, pinned by tests.
    static func isLive(_ record: Record, now: UInt64, claimant: Owner, processID: Int32) -> Bool {
        guard now < record.deadline else { return false }
        guard record.deadline - now <= UInt64(maximumDuration * 1_000_000_000) else { return false }
        // Only one app process exists at a time, so an app lease written by another pid belongs to
        // a run that is over — killed mid-request, its request died with it. A relaunch need not
        // sit out the dead run's lease. (Not assumed for the extension: iOS promises nothing about
        // how many of its processes there are.)
        if claimant == .app, record.owner == Owner.app.rawValue, record.processID != processID {
            return false
        }
        return true
    }

    /// Give the lease back. Idempotent, and safe from any thread (the app's request deadline fires
    /// off the main thread). Clears the record only while it is still this lease's: one that ran
    /// out may already belong to the next sender.
    func release() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !released else { return }
        released = true
        guard let path else { return }
        let token = token
        _ = Self.withRecord(atPath: path) { existing in
            ((), existing?.token == token ? .clear : .keep)
        }
        // A failure here costs nothing lasting: the record runs out at its deadline by itself.
    }

    deinit { release() }

    // MARK: - The record

    /// `<owner> <pid> <token> <deadline>` — one line of text, so a copy pulled off a phone
    /// (`devicectl`) reads at a glance.
    struct Record: Equatable {
        let owner: String
        let processID: Int32
        let token: String
        /// `CLOCK_MONOTONIC` nanoseconds (`monotonicNow`).
        let deadline: UInt64

        var encoded: Data {
            Data("\(owner) \(processID) \(token) \(deadline)\n".utf8)
        }

        init(owner: String, processID: Int32, token: String, deadline: UInt64) {
            self.owner = owner
            self.processID = processID
            self.token = token
            self.deadline = deadline
        }

        /// Nil for an empty (released) or unreadable file — both mean "nobody is sending".
        init?(decoding data: Data) {
            let fields = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: " ")
            guard fields.count == 4,
                  let processID = Int32(fields[1]),
                  let deadline = UInt64(fields[3]),
                  !fields[0].isEmpty, !fields[2].isEmpty else { return nil }
            self.init(owner: String(fields[0]), processID: processID, token: String(fields[2]), deadline: deadline)
        }
    }

    private enum Change {
        case keep
        case store(Record)
        case clear
    }

    private enum AccessFailure: Error {
        case unavailable(Int32)
        case contended
    }

    /// The ONLY place the file is locked. `body` decides from the current record; the change it
    /// returns is written before the lock is let go. Synchronous by construction — `body` cannot
    /// await — so the lock never outlives this call.
    private static func withRecord<T>(atPath path: String, _ body: (Record?) -> (T, Change)) -> Result<T, AccessFailure> {
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return .failure(.unavailable(errno)) }
        defer { close(descriptor) }

        // Never a blocking `flock`: the other process holds it for microseconds, but if it were
        // suspended inside that window a blocking call here would hang this thread — the app's
        // main thread — until it came back. A few 1 ms retries cover every honest collision.
        var locked = false
        for attempt in 0 ..< lockAttempts {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                locked = true
                break
            }
            if attempt + 1 < lockAttempts { usleep(1_000) }
        }
        guard locked else { return .failure(.contended) }
        defer { flock(descriptor, LOCK_UN) }

        var buffer = [UInt8](repeating: 0, count: 256)
        let count = buffer.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, 0) }
        let existing = count > 0 ? Record(decoding: Data(buffer.prefix(count))) : nil

        let (value, change) = body(existing)
        switch change {
        case .keep:
            break
        case .clear:
            ftruncate(descriptor, 0)
        case .store(let record):
            let data = record.encoded
            ftruncate(descriptor, 0)
            _ = data.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
        }
        return .success(value)
    }

    private static let lockAttempts = 20

    private init(path: String?, token: String) {
        self.path = path
        self.token = token
    }

    private let path: String?
    private let token: String
    private let stateLock = NSLock()
    private var released = false
}

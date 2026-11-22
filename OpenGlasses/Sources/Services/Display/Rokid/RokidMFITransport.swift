import Combine
import ExternalAccessory
import Foundation

/// Why an MFi session could not be opened or used. Separate from `GlassesDisplayError`
/// because these failures are all diagnosable from the phone side: "no accessory in the MFi
/// list" and "iOS refused the session" have different fixes.
enum RokidMFIError: LocalizedError, Equatable {
    /// No accessory is connected over the MFi transport.
    case noAccessory
    /// An accessory is connected but advertises none of our protocol strings. Carries the
    /// accessory names and every protocol string seen, because that list is exactly what says
    /// whether `Info.plist` needs a different entry.
    case unsupportedProtocol(accessories: [String], advertised: [String])
    /// `EASession` returned nil: iOS matched no accessory for the declared protocol, or the
    /// session is already open — Classic MFi usually allows one, and Rokid's own app may hold it.
    case sessionCreationFailed(protocolString: String)
    /// The session opened but vended no input/output stream.
    case streamsUnavailable
    case notConnected
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .noAccessory:
            return "No MFi accessory is connected. Pair the glasses over Bluetooth first."
        case .unsupportedProtocol(let accessories, let advertised):
            let names = accessories.isEmpty
                ? "the connected accessory"
                : accessories.joined(separator: ", ")
            let list = advertised.isEmpty ? "no MFi protocols" : advertised.joined(separator: ", ")
            return "\(names) does not speak com.rokid.aiglasses (advertises: \(list))."
        case .sessionCreationFailed(let protocolString):
            return "iOS refused an EASession for \(protocolString). Either the accessory is not "
                + "paired over MFi, or another app (Rokid's own) holds the session."
        case .streamsUnavailable:
            return "The MFi session opened without usable streams."
        case .notConnected:
            return "No open MFi session."
        case .writeFailed:
            return "The MFi output stream accepted no bytes."
        }
    }
}

/// The real Rokid command transport: Classic Bluetooth over an MFi `EASession`.
///
/// This is the transport the capture says exists. The GATT characteristics in
/// `RokidBLETransport` are a bootstrap only — the command channel is ACL handle 12, L2CAP CID
/// `0x0051` out and `0x0b08` back, carrying RFCOMM, carrying iAP2 `FF 5A` link packets whose
/// payload is a Caps tuple. See `docs/rokid-caps-encoding.md`.
///
/// **What iOS does for us.** MFi identification and authentication are performed by the
/// OS against the Apple Authentication Coprocessor at
/// `/sys/devices/platform/soc/988000.i2c/i2c-2/2-0010` (confirmed present on the device).
///
/// **What iOS does not do for us.** The glasses' CXR service ignores a session until the
/// app registers on it. The 2026-11-21 cold-connect capture shows the official app
/// sending a connect tuple on route `0x1004` — `(route, sequence, 15, uuid,
/// nanosecondsSinceEpoch, eapProtocolID, "")` — one millisecond after its session start,
/// and the glasses answering on route `0x1005` with the phone's Bluetooth address before
/// any `Dev` command is served. Opening the `EASession` alone is not enough; whichever
/// layer composes commands must send that hello first (the diagnostics probe does).
///
/// **Threading.** `EASession` streams must be scheduled on a run loop that is being pumped, so
/// the streams live on a dedicated `Thread` inside ``RokidMFIStreamCore``; only whole frames
/// cross back to the main actor. That core is a plain lock-guarded class rather than an actor
/// because `StreamDelegate` callbacks arrive on that thread and cannot `await`, and it is
/// declared at file scope rather than nested so that it does not inherit this type's
/// `@MainActor` isolation.
@MainActor
final class RokidMFITransport: NSObject, ObservableObject, RokidTransporting {

    /// The two `mfi.eap` names in the glasses' `cxr-service.json`, in preference order:
    /// `com.rokid.global.aiglasses` (id 195) FIRST — the 2026-11-21 PacketLogger capture
    /// of the official app shows its EAP session start (0xEA00) referencing protocol id
    /// 195, and the glasses' Caps service answers only on that session; a session opened
    /// on `com.rokid.aiglasses` (id 194) starts but is never answered. Both are declared
    /// in `Info.plist` under `UISupportedExternalAccessoryProtocols`.
    nonisolated static let protocolStrings = [
        "com.rokid.global.aiglasses",
        "com.rokid.aiglasses",
    ]

    /// Spelled as a literal rather than through the `EAAccessory` constant so this file does
    /// not depend on how the C symbol is Swift-renamed. The value is the framework's own.
    nonisolated static let didDisconnectNotificationName =
        Notification.Name("EAAccessoryDidDisconnectNotification")

    var onEvent: (([UInt8]) -> Void)?
    var onDisconnect: ((Error?) -> Void)?
    /// Called when an outbound write has to wait for the output stream to accept
    /// bytes — the write is queued, not lost. Carries the queued byte count.
    var onWriteWait: ((Int) -> Void)?

    /// Connected accessories that advertise one of ``protocolStrings``, for the pairing UI.
    @Published private(set) var discovered: [(id: String, name: String)] = []

    /// Settled on hardware — see ``RokidMFIFraming``. The MFi stack frames for us;
    /// writing an already-framed packet makes the accessory reject the payload and
    /// drop the session.
    var framing: RokidMFIFraming = .rawCaps

    var isConnected: Bool { core.isOpen }

    /// The protocol string the open session was created for. The CXR connect hello
    /// carries the string's EAP protocol id (`com.rokid.global.aiglasses` is 195,
    /// `com.rokid.aiglasses` is 194), so the layer that sends the hello reads it here.
    private(set) var connectedProtocolString: String?

    var connectedProtocolID: UInt32 {
        connectedProtocolString == "com.rokid.aiglasses" ? 194 : 195
    }

    private let core = RokidMFIStreamCore()

    override init() {
        super.init()
        core.onFrame = { [weak self] frame in
            Task { @MainActor in self?.onEvent?(frame) }
        }
        core.onFailed = { [weak self] error in
            Task { @MainActor in self?.onDisconnect?(error) }
        }
        core.onWriteWait = { [weak self] count in
            Task { @MainActor in self?.onWriteWait?(count) }
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(accessoryDidDisconnect),
            name: Self.didDisconnectNotificationName,
            object: nil
        )
        EAAccessoryManager.shared().registerForLocalNotifications()
        refresh()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Discovery

    /// Re-read the MFi accessory list. MFi has no scan: iOS surfaces an accessory once it is
    /// paired over Bluetooth *and* its protocol appears in `Info.plist`.
    func refresh() {
        discovered = EAAccessoryManager.shared().connectedAccessories.compactMap {
            accessory -> (id: String, name: String)? in
            guard !Self.matchingProtocols(for: accessory).isEmpty else { return nil }
            return (id: accessory.serialNumber, name: accessory.name)
        }
    }

    /// The subset of ``protocolStrings`` this accessory advertises, in preference order.
    nonisolated static func matchingProtocols(for accessory: EAAccessory) -> [String] {
        protocolStrings.filter { accessory.protocolStrings.contains($0) }
    }

    // MARK: - RokidTransporting

    func connect() async throws {
        if isConnected { return }
        let accessories = EAAccessoryManager.shared().connectedAccessories
        guard !accessories.isEmpty else { throw RokidMFIError.noAccessory }

        guard let accessory = accessories.first(where: { !Self.matchingProtocols(for: $0).isEmpty }),
              let protocolString = Self.matchingProtocols(for: accessory).first else {
            throw RokidMFIError.unsupportedProtocol(
                accessories: accessories.map(\.name),
                advertised: accessories.flatMap(\.protocolStrings)
            )
        }

        guard let session = EASession(accessory: accessory, forProtocol: protocolString) else {
            throw RokidMFIError.sessionCreationFailed(protocolString: protocolString)
        }
        guard session.inputStream != nil, session.outputStream != nil else {
            throw RokidMFIError.streamsUnavailable
        }

        connectedProtocolString = protocolString
        core.setRawCaps(framing == .rawCaps)
        core.open(session: session)
        refresh()
    }

    func disconnect() {
        core.close()
        connectedProtocolString = nil
        refresh()
    }

    func send(_ bytes: [UInt8]) async throws {
        guard isConnected else { throw RokidMFIError.notConnected }
        try await core.write(RokidMFIPayload.payload(for: bytes, framing: framing))
    }

    // MARK: - Notifications

    @objc private func accessoryDidDisconnect() {
        refresh()
        guard isConnected, discovered.isEmpty else { return }
        core.close()
        onDisconnect?(nil)
    }
}

// MARK: - Streams

/// Owns the `EASession` and its streams on their own run-loop thread.
///
/// Every member is called either under `lock` or from the stream thread. `onFrame`/`onFailed`
/// are assigned once, before ``open(session:)``, and never mutated afterwards.
/// One queued outbound write. The continuation resumes when the last byte is on
/// the stream, or throws when the stream errors or the session closes first.
private struct RokidPendingWrite {
    let id: UInt64
    let bytes: [UInt8]
    var offset = 0
    var waited = false
    let continuation: CheckedContinuation<Void, Error>
}

private final class RokidMFIStreamCore: NSObject, StreamDelegate {

    var onFrame: (([UInt8]) -> Void)?
    var onFailed: ((Error?) -> Void)?
    /// Called once per write that cannot go out immediately, with its byte count.
    var onWriteWait: ((Int) -> Void)?

    private let lock = NSLock()
    /// Outbound writes waiting for the output stream, oldest first. The stream
    /// refuses a write attempted before it signals space — the `writeFailed`s the
    /// session layer logged when the answer choreography sent back-to-back in one
    /// tick (2026-11-21) — so writes queue here and drain only while
    /// `hasSpaceAvailable` holds. One drainer at a time; order is FIFO.
    private var pendingWrites: [RokidPendingWrite] = []
    private var nextWriteID: UInt64 = 0
    private var drainActive = false
    private var session: EASession?
    private var input: InputStream?
    private var output: OutputStream?
    private var thread: Thread?
    private var drain = RokidFrameDrain()
    private var rawCaps = true
    private var rawCapsPending: [UInt8] = []
    private var closing = false

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return session != nil && input != nil && output != nil && !closing
    }

    func setRawCaps(_ value: Bool) {
        lock.lock()
        rawCaps = value
        lock.unlock()
    }

    func open(session: EASession) {
        lock.lock()
        self.session = session
        self.input = session.inputStream
        self.output = session.outputStream
        self.closing = false
        self.drain.reset()
        self.rawCapsPending.removeAll(keepingCapacity: true)
        lock.unlock()

        let thread = Thread { [weak self] in self?.runStreamLoop() }
        thread.name = "RokidMFITransport.streams"
        thread.stackSize = 512 * 1024
        lock.lock()
        self.thread = thread
        lock.unlock()
        thread.start()
    }

    /// Queue one write and suspend until it is fully on the stream. A stream that
    /// has no space right now is a wait, not a failure: the write leaves when the
    /// stream signals `hasSpaceAvailable`. Throws only on a real stream error or
    /// when the session closes with the write still queued.
    func write(_ bytes: [UInt8]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            guard !closing, output != nil else {
                lock.unlock()
                continuation.resume(throwing: RokidMFIError.notConnected)
                return
            }
            let id = nextWriteID
            nextWriteID &+= 1
            pendingWrites.append(RokidPendingWrite(id: id, bytes: bytes, continuation: continuation))
            lock.unlock()
            drainQueue()
        }
    }

    private func drainQueue() {
        lock.lock()
        if drainActive {
            lock.unlock()
            return
        }
        drainActive = true
        lock.unlock()

        while drainStep() {}

        lock.lock()
        drainActive = false
        let pending = !pendingWrites.isEmpty && !closing
        lock.unlock()
        // A write enqueued while this drain was finishing saw `drainActive` and
        // stepped aside; if it is still queued, it is this drain's to pick up.
        if pending { drainQueue() }
    }

    /// One drain quantum: write as much of the queue head as the stream takes.
    /// Returns true when the queue may hold more that can go out right now.
    private func drainStep() -> Bool {
        lock.lock()
        guard let stream = output, !pendingWrites.isEmpty, !closing else {
            lock.unlock()
            return false
        }
        var head = pendingWrites[0]
        lock.unlock()

        guard stream.hasSpaceAvailable else {
            markWaited()
            return false
        }

        let written = head.bytes.withUnsafeBufferPointer { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            return stream.write(base.advanced(by: head.offset), maxLength: head.bytes.count - head.offset)
        }

        if written > 0 {
            head.offset += written
            lock.lock()
            // The queue may have been torn down by `close()` while the write was
            // in flight; only the still-queued head is this drain's to finish.
            if pendingWrites.first?.id == head.id {
                if head.offset >= head.bytes.count {
                    pendingWrites.removeFirst()
                    lock.unlock()
                    head.continuation.resume()
                } else {
                    pendingWrites[0] = head
                    lock.unlock()
                }
            } else {
                lock.unlock()
            }
            return true
        }
        if written < 0 {
            lock.lock()
            let stillQueued = pendingWrites.first?.id == head.id
            if stillQueued { pendingWrites.removeFirst() }
            lock.unlock()
            if stillQueued {
                head.continuation.resume(throwing: RokidMFIError.writeFailed)
            }
            return false
        }
        // written == 0: the stream took nothing despite the flag — wait for the
        // next space-available event rather than failing the write.
        markWaited()
        return false
    }

    private func markWaited() {
        lock.lock()
        var count: Int?
        if !pendingWrites.isEmpty, !pendingWrites[0].waited {
            pendingWrites[0].waited = true
            count = pendingWrites[0].bytes.count
        }
        lock.unlock()
        if let count { onWriteWait?(count) }
    }

    /// Tear down without notifying — the caller decides whether this close is worth reporting.
    func close() {
        lock.lock()
        closing = true
        let pending = pendingWrites
        pendingWrites.removeAll()
        input?.close()
        output?.close()
        session = nil
        input = nil
        output = nil
        lock.unlock()
        for item in pending {
            item.continuation.resume(throwing: RokidMFIError.notConnected)
        }
    }

    private func isClosing() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return closing
    }

    /// Pump the run loop the streams are scheduled on until ``close()``.
    private func runStreamLoop() {
        lock.lock()
        let input = self.input
        let output = self.output
        lock.unlock()
        guard let input, let output else { return }

        input.delegate = self
        output.delegate = self
        input.schedule(in: .current, forMode: .default)
        output.schedule(in: .current, forMode: .default)
        input.open()
        output.open()

        while !isClosing() {
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.25))
        }

        input.close()
        output.close()
        input.remove(from: .current, forMode: .default)
        output.remove(from: .current, forMode: .default)
    }

    private func readAvailableBytes() {
        lock.lock()
        let stream = input
        lock.unlock()
        guard let stream else { return }

        var chunk = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let read = stream.read(&chunk, maxLength: chunk.count)
            guard read > 0 else { break }

            let bytes = Array(chunk[0..<read])
            lock.lock()
            let raw = rawCaps
            let frames = raw ? [] : drain.append(bytes)
            lock.unlock()

            if raw {
                var blobs: [[UInt8]] = []
                lock.lock()
                rawCapsPending.append(contentsOf: bytes)
                while rawCapsPending.count >= 4 {
                    let total = Int(rawCapsPending[0]) << 24 | Int(rawCapsPending[1]) << 16 | Int(rawCapsPending[2]) << 8 | Int(rawCapsPending[3])
                    guard total >= 6, total <= 65_536 else {
                        rawCapsPending.removeFirst()
                        continue
                    }
                    guard rawCapsPending.count >= total else { break }
                    blobs.append(Array(rawCapsPending.prefix(total)))
                    rawCapsPending.removeFirst(total)
                }
                lock.unlock()
                for blob in blobs { onFrame?(blob) }
            } else {
                for frame in frames { onFrame?(frame) }
            }
        }
    }

    /// A stream failure is the one close worth reporting: the session died underneath us.
    private func failed(_ error: Error?) {
        close()
        onFailed?(error)
    }

    func stream(_ stream: Stream, handle eventCode: Stream.Event) {
        // `Stream.Event` is an OptionSet, not an enum: cases can arrive combined, so no
        // `switch` over it can ever be exhaustive and the enum-only wildcard arm does not
        // compile. Worse, equality-matched switch cases would let a combined
        // `hasBytesAvailable | endEncountered` fall through as if it were plain data, so
        // the two terminal events are tested first with `contains`.
        if eventCode.contains(.errorOccurred) {
            failed(stream.streamError)
            return
        }
        if eventCode.contains(.endEncountered) {
            failed(nil)
            return
        }
        if eventCode.contains(.hasSpaceAvailable) {
            drainQueue()
        }
        if eventCode.contains(.hasBytesAvailable) {
            readAvailableBytes()
        }
    }
}

import Combine
import CryptoKit
import Foundation

/// A registered CXR session with the Rokid RV101: the layer that turns the raw MFi
/// transport into the conversation the glasses actually expect.
///
/// Everything here is proven on hardware (2026-11-21; the full recipe is written up in
/// `docs/rokid-hardware-validation.md`, "PROVEN ON HARDWARE"):
///
/// 1. The transport opens the `EASession` on `com.rokid.global.aiglasses` (protocol id
///    195). On 194 the session opens and the glasses never send a byte.
/// 2. This layer immediately sends the registration hello on route `0x1004` —
///    `(route, seq, 15, clientUUID, nanosecondsSinceEpoch, protocolID, "")`. The glasses
///    answer on route `0x1005` with a status and the phone's Bluetooth address. Until
///    this exchange completes, the CXR service ignores every command on the session.
/// 3. Commands are `uuSO` tuples on route `0x1001`; replies arrive on `0x1002` echoing
///    the sequence; glasses-initiated events arrive on `0x1003` (and user-action events
///    on `0x2001`). This layer owns the sequence counter, decodes inbound tuples, tracks
///    the state the glasses volunteer (AI scene, screen, battery), and surfaces the rest
///    through callbacks.
/// 4. Text reaches the lens only inside the glasses-opened AI scene (wake word "Hi
///    Rokid"), via the paced answer choreography in ``presentAnswer(question:answer:)``.
///
/// The glasses also make requests of their host — weather data, contacts — which this
/// layer surfaces through ``onEvent`` but does not yet answer.
@MainActor
final class RokidCXRSession: ObservableObject {

    /// The client identity the glasses answer to today: the official app's UUID,
    /// recovered from the 2026-11-21 cold-connect capture. Registration is keyed to
    /// this string — a freshly generated UUID is ignored even on a fresh link
    /// (controlled test, 2026-11-21) — and how a *new* UUID becomes registered is
    /// unknown. Until that is solved, this is the identity a client must present.
    nonisolated static let registeredClientUUID = "7050c2b0-ce7a-43e4-9d12-ccf78672aa23"

    // MARK: - State

    @Published private(set) var isConnected = false
    /// True once the glasses have answered the registration hello with status 1.
    @Published private(set) var isRegistered = false
    @Published private(set) var registrationStatus: Int32?
    /// The phone's Bluetooth address as the glasses know it, from the hello reply.
    @Published private(set) var phoneBluetoothAddress: String?
    /// True while the glasses' AI assistant scene is open (wake word or button).
    @Published private(set) var aiSceneActive = false
    @Published private(set) var screenOn: Bool?
    @Published private(set) var batteryLevel: Int?
    /// The sequence number the next command will carry.
    @Published private(set) var nextSequence: UInt32 = 1
    @Published private(set) var bytesIn = 0
    @Published private(set) var bytesOut = 0
    /// Route `0x3002` chunks received (microphone audio while the AI scene listens).
    /// Counted, not traced — a listening scene produces ~25 a second.
    @Published private(set) var audioChunksReceived = 0
    /// Route `0x2002` chunks in the current (or last completed) photo transfer.
    /// Counted, not traced — a photo is ~200 chunks.
    @Published private(set) var photoChunksReceived = 0
    /// The last completed photo, reassembled from its chunks (JPEG on the
    /// media-sync path, WEBP on the October Ai path). Set when a transfer
    /// completes: a short final chunk, or an MD5 match against the glasses'
    /// own `Med_TransportMediaFile` announcement.
    @Published private(set) var lastPhoto: Data?

    // MARK: - Callbacks

    /// Decoded replies (`0x1002`) and user-action events (`0x2001`).
    var onMessage: ((RokidCapsMessage) -> Void)?
    /// Glasses-initiated events (route `0x1003`): channel, method, payload.
    var onEvent: ((String, String, RokidCapsValue?) -> Void)?
    /// Microphone audio chunks from the glasses (route `0x3002`).
    var onAudioChunk: ((Data) -> Void)?
    /// A completed photo from the glasses (route `0x2002`, reassembled).
    var onPhoto: ((Data) -> Void)?
    /// One human-readable line per send, receive, and state change.
    var onTrace: ((String) -> Void)?
    var onDisconnect: ((Error?) -> Void)?

    // MARK: - Internals

    private let transport: RokidMFITransport
    private let clientUUID: String
    private var sequence: UInt32 = 1
    /// In-flight media transfers, keyed by route (`0x2002` photo, `0x2003` opaque).
    private var photoAssembly: [UInt32: Data] = [:]
    /// Running MD5 of the in-flight `0x2002` transfer, checked against the
    /// glasses' `Med_TransportMediaFile` announcement.
    private var photoMD5 = Insecure.MD5()
    /// The file the glasses last announced over `Med_TransportMediaFile`.
    private var announcedMediaFileName: String?
    private var announcedMediaMD5: String?
    /// Bumped on every photo chunk and every completion; a quiet-period task
    /// fires only if its captured generation is still current after sleeping.
    private var photoGeneration = 0

    init(
        clientUUID: String = RokidCXRSession.registeredClientUUID,
        transport: RokidMFITransport? = nil
    ) {
        self.clientUUID = clientUUID
        self.transport = transport ?? RokidMFITransport()
        self.transport.onEvent = { [weak self] bytes in
            Task { @MainActor in self?.handleInbound(bytes) }
        }
        self.transport.onDisconnect = { [weak self] error in
            Task { @MainActor in self?.handleTransportDisconnect(error) }
        }
        self.transport.onWriteWait = { [weak self] count in
            Task { @MainActor in self?.trace("TX wait: output stream busy — write queued (\(count) B)") }
        }
    }

    /// The underlying transport, exposed for diagnostics that need to step outside the
    /// session model (the probe's framing experiments). Product code should not use it.
    var diagnosticsTransport: RokidMFITransport { transport }

    // MARK: - Connection

    /// Open the session and register with the CXR service. Registration completes
    /// asynchronously — watch ``isRegistered`` for the glasses' answer.
    func connect() async throws {
        transport.framing = .rawCaps
        try await transport.connect()
        isConnected = transport.isConnected
        if isConnected {
            sequence = 1
            nextSequence = 1
            isRegistered = false
            registrationStatus = nil
            phoneBluetoothAddress = nil
            await sendHello()
        }
    }

    func disconnect() {
        transport.disconnect()
        isConnected = false
        isRegistered = false
        aiSceneActive = false
        photoAssembly.removeAll()
    }

    private func handleTransportDisconnect(_ error: Error?) {
        isConnected = false
        isRegistered = false
        aiSceneActive = false
        trace("disconnected: \(error.map { String(describing: $0) } ?? "closed by the accessory")")
        onDisconnect?(error)
    }

    // MARK: - Registration

    /// The CXR connect hello, decoded from the 2026-11-21 cold-connect capture: a
    /// seven-member tuple on route `0x1004` — `(route, sequence, 15, uuid,
    /// nanosecondsSinceEpoch, eapProtocolID, "")`. The glasses answer on route `0x1005`
    /// with `(route, sequence, 15, status, phoneBluetoothAddress)`. Member 3 is 15 in
    /// both directions of the captured exchange; its meaning is unknown.
    private func sendHello() async {
        let blob = RokidCapsCodec.encode([
            .uint32(0x1004),
            .uint32(sequence),
            .uint32(15),
            .string(clientUUID),
            .uint64(UInt64(Date().timeIntervalSince1970 * 1_000_000_000)),
            .uint32(transport.connectedProtocolID),
            .string(""),
        ])
        do {
            try await transport.send(blob)
            bytesOut += blob.count
            sequence &+= 1
            nextSequence = sequence
            trace("TX CXR hello (route 0x1004, protocol id \(transport.connectedProtocolID)) \(blob.count) B")
        } catch {
            trace("TX CXR hello failed: \(String(describing: error))")
        }
    }

    // MARK: - Commands

    /// Send one `uuSO` command on route `0x1001`. Replies, when the glasses send one,
    /// arrive through ``onMessage`` carrying the same sequence number.
    func sendCommand(channel: String, method: String, payload: RokidCapsValue?) async throws {
        guard isConnected else { throw RokidMFIError.notConnected }
        var object: [RokidCapsValue] = [.string(method)]
        if let payload { object.append(payload) }
        let caps: [RokidCapsValue] = [
            .uint32(RokidCapsRoute.request.rawValue),
            .uint32(sequence),
            .string(channel),
            .object(object),
        ]
        let blob = RokidCapsCodec.encode(caps)
        let used = sequence
        try await transport.send(blob)
        bytesOut += blob.count
        sequence &+= 1
        nextSequence = sequence
        trace("TX \(channel)/\(method) seq \(used) (\(blob.count) B)")
    }

    /// Write bytes below the session model (the probe's raw sender). The transport's
    /// rawCaps policy still applies: a full `ff 5a` frame is stripped to its Caps blob,
    /// anything else passes through untouched.
    func sendRaw(_ bytes: [UInt8]) async throws {
        guard isConnected else { throw RokidMFIError.notConnected }
        try await transport.send(bytes)
        bytesOut += bytes.count
        trace("TX raw \(bytes.count) B")
    }

    /// The safest first command: a status read the glasses answer without changing state.
    func getGlassInfo() async throws {
        try await sendCommand(channel: "Dev", method: "Dev_GetGlassInfo", payload: nil)
    }

    func sendHeartbeat() async throws {
        try await sendCommand(channel: "Ai", method: "Ai_Heartbeat", payload: .string("{\"count\":1}"))
    }

    /// Ask the glasses for a still. The image streams back on route `0x2002` in
    /// 480-byte chunks and surfaces through ``lastPhoto`` / ``onPhoto`` when a short
    /// chunk ends the transfer. Whether `Ai_OpenCamera` must precede this is
    /// unproven — the SDK issues both commands; the probe tries TakePhoto first.
    func takePhoto(width: Int = 1280, height: Int = 960, quality: Int = 80) async {
        await sendOrTrace(channel: "Ai", method: "Ai_TakePhoto",
                          payload: .string(RokidCXRCommand.json(["width": width, "height": height, "quality": quality])))
    }

    /// Open the glasses' camera for the AI flow (the SDK's companion to TakePhoto).
    func openCamera(width: Int = 1280, height: Int = 960, quality: Int = 80) async {
        await sendOrTrace(channel: "Ai", method: "Ai_OpenCamera",
                          payload: .string(RokidCXRCommand.json(["width": width, "height": height, "quality": quality])))
    }

    // MARK: - Presenting an answer

    /// Display `answer` on the lens as the reply to `question`, inside an AI scene the
    /// glasses have already opened (wake word "Hi Rokid" — watch ``aiSceneActive``).
    ///
    /// Paced to match the official app's captured timing (2026-11-21 cold-connect
    /// capture, Q&A at 10:56:57–10:57:03): cloud status and a heartbeat as the scene
    /// opens, `ASR_Result` partials building the question word by word, `ASR_End`, a
    /// ~1.8 s "thinking" pause, a second heartbeat, then the answer as `TTS_Result`.
    /// Firing the same sends in a single burst rendered nothing — the glasses' scene
    /// state machine needs the beats. Sends that fail are traced, not thrown: a partial
    /// performance beats an exception halfway through the choreography.
    func presentAnswer(question: String, answer: String) async {
        await sendOrTrace(channel: "Sys", method: "Sys_Cloud_Server_Status", payload: .string("{\"status\":1}"))
        await sendOrTrace(channel: "Ai", method: "Ai_Heartbeat", payload: .string("{\"count\":1}"))
        let partials = Self.partials(for: question)
        for (index, partial) in partials.enumerated() {
            if index > 0 { try? await Task.sleep(nanoseconds: 450_000_000) }
            await sendOrTrace(channel: "Ai", method: "ASR_Result", payload: .string(partial))
        }
        await sendOrTrace(channel: "Ai", method: "ASR_End", payload: nil)
        try? await Task.sleep(nanoseconds: 1_800_000_000)
        await sendOrTrace(channel: "Ai", method: "Ai_Heartbeat", payload: .string("{\"count\":1}"))
        await sendOrTrace(channel: "Ai", method: "TTS_Result", payload: .string(answer))
    }

    /// Cumulative word prefixes: "Who is Avenkin?" → "Who", "Who is", "Who is Avenkin?".
    private static func partials(for question: String) -> [String] {
        let words = question.split(separator: " ")
        return (0..<words.count).map { words[0...$0].joined(separator: " ") }
    }

    private func sendOrTrace(channel: String, method: String, payload: RokidCapsValue?) async {
        do {
            try await sendCommand(channel: channel, method: method, payload: payload)
        } catch {
            trace("TX \(channel)/\(method) failed: \(String(describing: error))")
        }
    }

    // MARK: - Inbound

    private func handleInbound(_ bytes: [UInt8]) {
        bytesIn += bytes.count
        var offset = 0
        guard let caps = try? RokidCapsCodec.decode(bytes, offset: &offset), offset == bytes.count,
              let first = caps.first, case .uint32(let route) = first else {
            trace("RX \(bytes.count) B: not a decodable Caps blob")
            return
        }

        switch route {
        case 0x1005:
            handleHelloReply(caps)
        case 0x1003:
            guard caps.count == 3, case .string(let channel) = caps[1],
                  case .object(let members) = caps[2],
                  let firstMember = members.first, case .string(let method) = firstMember else {
                trace("RX event (route 0x1003) with an unexpected shape")
                return
            }
            let payload = members.count > 1 ? members[1] : nil
            applyEvent(channel: channel, method: method, payload: payload)
            onEvent?(channel, method, payload)
        case 0x2002, 0x2003:
            handlePhotoChunk(route: route, caps: caps)
        case 0x3002:
            audioChunksReceived += 1
            if caps.count > 1, case .binary(let data) = caps[1] {
                onAudioChunk?(data)
            }
        default:
            if let message = RokidCapsMessage.decodeCaps(caps) {
                switch message {
                case .reply(_, let seq, let method, _):
                    trace("RX reply \(method) seq \(seq)")
                case .notification(_, let channel, let method, let payload):
                    // Route 0x2001 user-action events decode as notifications.
                    applyEvent(channel: channel, method: method, payload: payload)
                    onEvent?(channel, method, payload)
                case .request:
                    trace("RX unexpected request-shaped tuple, method \(message.method)")
                }
                onMessage?(message)
            } else {
                trace("RX route \(String(route, radix: 16)) (\(bytes.count) B), tags \(caps.map { String($0.typeTag) }.joined())")
            }
        }
    }

    /// Reassemble one media transfer (routes `0x2002` photo, `0x2003` opaque):
    /// `uB` chunks of 480 bytes, concatenated in arrival order; a chunk shorter
    /// than 480 ends the transfer — the shape ``RokidMediaTransfer`` documents
    /// from the October captures, where a photo arrived as 198 chunks of WEBP.
    /// Individual chunks are counted, not traced; the start (with the first
    /// bytes, where a `RIFF` header shows) and the completion are traced.
    private func handlePhotoChunk(route: UInt32, caps: [RokidCapsValue]) {
        guard caps.count >= 2, case .binary(let data) = caps[1] else {
            trace("RX route \(String(route, radix: 16)): media frame without a binary member")
            return
        }
        var buffer = photoAssembly[route] ?? Data()
        // File boundary inside one continuous stream: the firmware sends NO
        // end-of-image marker — two complete 432x576 previews dissected on
        // 2026-11-22 contained zero FF D9 between them and each decoded whole,
        // short only its final ~67 B. So the next file's start-of-image
        // (FF D8 FF) at a chunk boundary is the only delimiter there is. A bare
        // FF D8 cannot occur inside a file's entropy data (FF is escaped as
        // FF 00 there), so an SOI at a chunk start means a new file.
        if route == 0x2002, !buffer.isEmpty, data.count > 3,
           data[0] == 0xFF, data[1] == 0xD8, data[2] == 0xFF {
            photoAssembly[route] = nil
            completePhotoTransfer(buffer: buffer, verified: false, boundary: true)
            buffer = Data()
        }
        if buffer.isEmpty {
            if route == 0x2002 {
                photoChunksReceived = 0
                photoMD5 = Insecure.MD5()
            }
            let magic = data.prefix(12).map { String(format: "%02x", $0) }.joined(separator: " ")
            trace("RX media transfer started on route \(String(route, radix: 16)): first chunk \(data.count) B [\(magic)]")
        }
        buffer.append(data)
        if route == 0x2002 {
            photoChunksReceived += 1
            photoMD5.update(data: data)
            // The media-sync flow announces the file (name + MD5) over
            // `Med_TransportMediaFile` while its chunks are still flowing, and
            // in the 2026-11-22 button-press test no short final chunk ever
            // arrived — so a digest match against the announcement is a
            // completion proof of its own.
            if let expected = announcedMediaMD5 {
                var hasher = photoMD5
                let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                if digest == expected {
                    photoAssembly[route] = nil
                    completePhotoTransfer(buffer: buffer, verified: true)
                    return
                }
            }
        }
        if data.count < 480 {
            photoAssembly[route] = nil
            if route == 0x2002 {
                completePhotoTransfer(buffer: buffer, verified: false)
            } else {
                trace("RX media transfer complete on route \(String(route, radix: 16)): \(buffer.count) B")
            }
        } else {
            photoAssembly[route] = buffer
            if route == 0x2002 { armPhotoQuietFinalizer() }
        }
    }

    private func completePhotoTransfer(buffer: Data, verified: Bool, boundary: Bool = false, quiet: Bool = false) {
        photoGeneration += 1
        lastPhoto = buffer
        let name = announcedMediaFileName ?? "photo"
        let digest = Insecure.MD5.hash(data: buffer).map { String(format: "%02x", $0) }.joined()
        trace("RX photo complete: \(buffer.count) B in \(photoChunksReceived) chunks (\(name))\(verified ? " — MD5 verified" : "")\(boundary ? " — JPEG boundary" : "")\(quiet ? " — stream quiet" : "") md5 \(digest)")
        announcedMediaFileName = nil
        announcedMediaMD5 = nil
        onPhoto?(buffer)
    }

    /// The last photo in a stream has no next SOI to flush it, so when the
    /// chunks stop for 12 s the in-flight assembly is finalized as-is — the
    /// firmware's previews decode fine short their final bytes.
    private func armPhotoQuietFinalizer() {
        photoGeneration += 1
        let generation = photoGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard let self, generation == self.photoGeneration,
                  let buffer = self.photoAssembly[0x2002], !buffer.isEmpty else { return }
            self.photoAssembly[0x2002] = nil
            self.completePhotoTransfer(buffer: buffer, verified: false, quiet: true)
        }
    }

    /// The in-flight `0x2002` assembly, however many files it currently spans —
    /// exposed so the probe can save the raw stream for offline dissection.
    var photoAssemblySnapshot: Data { photoAssembly[0x2002] ?? Data() }

    private func handleHelloReply(_ caps: [RokidCapsValue]) {
        guard caps.count >= 5 else {
            trace("RX CXR hello reply with an unexpected shape")
            return
        }
        if case .int32(let status) = caps[3] {
            registrationStatus = status
            isRegistered = status == 1
        }
        if case .string(let address) = caps[4] {
            phoneBluetoothAddress = address
        }
        trace("RX CXR hello reply: status \(registrationStatus.map(String.init) ?? "-"), phone address \(phoneBluetoothAddress ?? "-") — session registered")
    }

    /// Fold the state the glasses volunteer into the published properties.
    private func applyEvent(channel: String, method: String, payload: RokidCapsValue?) {
        var detail = ""
        if case .string(let text)? = payload {
            detail = " " + text
            switch method {
            case "Ai_SceneStatus":
                if let json = Self.jsonObject(text), let running = json["aiAssistRunning"] as? Bool {
                    aiSceneActive = running
                }
            case "Dev_Screen_Status":
                if let json = Self.jsonObject(text), let on = json["screen_on"] as? Bool {
                    screenOn = on
                }
            case "Dev_BatteryChanged":
                if let json = Self.jsonObject(text), let level = json["level"] as? Int {
                    batteryLevel = level
                }
            case "Med_TransportMediaFile":
                if let json = Self.jsonObject(text) {
                    announcedMediaFileName = json["fileName"] as? String
                    announcedMediaMD5 = json["md5"] as? String
                }
            default:
                break
            }
        }
        trace("RX event \(channel)/\(method)\(detail)")
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return object as? [String: Any]
    }

    private func trace(_ line: String) {
        onTrace?(line)
    }
}

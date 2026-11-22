import Combine
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

    // MARK: - Callbacks

    /// Decoded replies (`0x1002`) and user-action events (`0x2001`).
    var onMessage: ((RokidCapsMessage) -> Void)?
    /// Glasses-initiated events (route `0x1003`): channel, method, payload.
    var onEvent: ((String, String, RokidCapsValue?) -> Void)?
    /// Microphone audio chunks from the glasses (route `0x3002`).
    var onAudioChunk: ((Data) -> Void)?
    /// One human-readable line per send, receive, and state change.
    var onTrace: ((String) -> Void)?
    var onDisconnect: ((Error?) -> Void)?

    // MARK: - Internals

    private let transport: RokidMFITransport
    private let clientUUID: String
    private var sequence: UInt32 = 1

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

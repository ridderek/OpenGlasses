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
    /// Route `0x3002` chunks in the current (or last completed) mic clip.
    @Published private(set) var micChunksReceived = 0
    /// The last completed microphone clip, reassembled from its chunks —
    /// an Ogg-Opus byte stream (16 kHz mono), directly saveable as `.opus`.
    /// Set when the stream goes quiet or the AI scene closes.
    @Published private(set) var lastMicClip: Data?

    // MARK: - Callbacks

    /// Decoded replies (`0x1002`) and user-action events (`0x2001`).
    var onMessage: ((RokidCapsMessage) -> Void)?
    /// Glasses-initiated events (route `0x1003`): channel, method, payload.
    var onEvent: ((String, String, RokidCapsValue?) -> Void)?
    /// Microphone audio chunks from the glasses (route `0x3002`).
    var onAudioChunk: ((Data) -> Void)?
    /// A completed photo from the glasses (route `0x2002`, reassembled).
    var onPhoto: ((Data) -> Void)?
    /// A completed microphone clip from the glasses (route `0x3002`, reassembled).
    var onMicClip: ((Data) -> Void)?
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
    /// In-flight microphone assembly (route `0x3002` inbound): the Ogg-Opus
    /// byte stream, concatenated in arrival order — Ogg is a byte stream,
    /// so arrival order is file order.
    private var micAssembly = Data()
    /// Bumped on every mic chunk and every completion; a quiet-period task
    /// fires only if its captured generation is still current after sleeping.
    private var micGeneration = 0

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

    // MARK: - Audio playback

    /// Play the embedded test chirp through the glasses' speaker: the audio-down
    /// path, recovered from the 2026-11-21 cold-connect capture and re-mined
    /// 2026-11-23. In the captured flow the glasses announced their audio session
    /// (`AI_assistant` on route `0x3001`, descriptor `ifuu` = 1, 1.0, 1, 16000) as
    /// the AI scene opened; the phone answered with a `playAudio` descriptor on
    /// `0x3001`, streamed the answer as `uBuk` chunks on `0x3002`, and sent a stop
    /// tuple on `0x3003` carrying the playback id. The answer itself was MP3 at
    /// 16 kHz mono (Lavf-encoded, like the chirp below), in chunks of up to
    /// 2,048 B. Outbound chunk members per the codec's frame survey: the selector
    /// `u` is only ever 3 or 4 and the clock `k` is 0.
    ///
    /// The full official answer shape: the paced choreography first (cloud
    /// status, heartbeat, ASR partials, ASR_End, thinking pause, heartbeat,
    /// TTS_Result), then the chirp stream attached to that utterance. Tests
    /// whether the glasses only route playAudio audio to the speaker while a
    /// TTS utterance is open: three bare playTestTone streams (2026-11-23)
    /// were accepted — Tts_PlayStart, Tts_PlayFinish result 1 — yet silent,
    /// at both whisper-level and near-full-scale chirp amplitudes. PROVEN
    /// 2026-11-23: with the utterance declared, the chirp was heard aloud
    /// through the glasses' speaker. The utterance is the gate — audio
    /// down rides TTS_Result.
    func playSpokenTest() async {
        await presentAnswer(question: "What is the test tone?", answer: "Three notes, rising.")
        await playTestTone()
    }

    func playTestTone() async {
        guard isConnected else {
            trace("TX playAudio skipped: not connected")
            return
        }
        let descriptor: [RokidCapsValue] = [
            .uint32(RokidCapsRoute.audioPlay.rawValue),
            .uint32(sequence),
            .string("playAudio"),
            .object([.int32(-1), .float(1.0), .uint32(1), .uint32(16000)]),
            .uint32(2),
            .uint32(3),
        ]
        if await sendAudioTuple(descriptor, label: "playAudio (route 0x3001)") {
            sequence &+= 1
            nextSequence = sequence
        }
        let mp3 = Self.testToneMP3
        var offset = 0
        var chunks = 0
        while offset < mp3.count {
            let end = min(offset + 1024, mp3.count)
            let tuple: [RokidCapsValue] = [
                .uint32(RokidCapsRoute.audioData.rawValue),
                .binary(mp3.subdata(in: offset..<end)),
                .uint32(3),
                .uint64(0),
            ]
            _ = await sendAudioTuple(tuple, label: nil)
            chunks += 1
            offset = end
            if offset < mp3.count { try? await Task.sleep(nanoseconds: 120_000_000) }
        }
        trace("TX audio stream: \(chunks) chunks, \(mp3.count) B of MP3 (16 kHz mono)")
        try? await Task.sleep(nanoseconds: 500_000_000)
        _ = await sendAudioTuple(
            [.uint32(RokidCapsRoute.audioStop.rawValue), .uint32(2)],
            label: "audio stop (route 0x3003)")
    }

    /// Encode and send one audio-route tuple; returns whether the write landed.
    /// Traced only when a label is given — chunks are counted by the caller.
    private func sendAudioTuple(_ caps: [RokidCapsValue], label: String?) async -> Bool {
        let blob = RokidCapsCodec.encode(caps)
        do {
            try await transport.send(blob)
            bytesOut += blob.count
            if let label { trace("TX \(label) (\(blob.count) B)") }
            return true
        } catch {
            trace("TX \(label ?? "audio chunk") failed: \(String(describing: error))")
            return false
        }
    }

    /// The test chirp, synthesized sample-exact (16 kHz mono, MP3 64 kbps —
    /// the official stream's own format — 1.4 s, near full scale) and embedded
    /// base64 so the probe needs no bundled resource. Spliced in from chirp.b64
    /// by script and verified byte-identical after splicing; do not hand-edit.
    private static let testToneMP3: Data = Data(base64Encoded:
        "//OIwAAAAAAAAAAAAEluZm8AAAAPAAAAKQAAL0AADAwSEhgYGB4eJCQkKiowMDA2Njw8Q0NDSUlPT09VVVtbW2FhZ2dnbW1zc3l5eYCAhoaGjIySkpKYmJ6epKSkqqqwsLC2try8vMPDycnJz8/V1dvb2+Hh5+fn" +
        "7e3z8/P5+f//AAAAAExhdmM2Mi4yOAAAAAAAAAAAAAAAACQCgAAAAAAAAC9APN0buQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA//OIxAA5wcoQAVzoAaeVw27bW2HrDpDoPltC0hZAwAADAQEMDAgwYEDCgYMOBgxWKTFYvMZjcx2QzJJRMplEyeYzUsfPd/U7" +
        "irQ5mcIzOJs2nm0771k+F4E9RvM5jZ0yTHw2HdE3ZaU1bQ0zNJ0x7GMxREUw5DMwtCkwlB0wmB4wcBowWBQwQA4wMAowIAYwEAIwCAADAAAgHLNlty5aAdFdItMdTdQRUipF2LsZwzhnDXGvuW5bluW77/v/D7+P" +
        "4/j+Q5GIxGJZG43G43G43T09PSUlJSUlJSUlinp6ent5h4YAAAAAB4eHh4YAAAA7///wAAIEkZKX9TEYTEn6Zyvot+OjZDAJZI0mLtHyi6UEQWAFTAHAB8wF4CFCoBcY//OIxCxBGrIwq5j4AAeAC5gc4GKncUAC" +
        "xgHwD6YYCQ4GunIoxhrgbQYBmAkGFiDc52uZTgZlYBFGBogCRgu4eGdylTAmOIhnIEADSIAzbxqL9SsBAehgHIBCYAcAEjwA+BgAgvQjVDTwwdJ71BZ3VQeTgUHYi0NrlWPUeVW9lqtjjVya82jlu7A7+Q9jruW+" +
        "Y3K2OOOWWWMORuWxeWS6WU87n398/Xf3vLLXOY/3Xz9S1Yzs28L9jO9/N5d/+f//vH/1/P///n/TkQiAyJwylc84WeLqW4Wo8og+BEHxyD4WijtasoqH+r/+fAwCBgMTnIDUaMAzWKDASwLowWkKIMMxCyDDYR4o" +
        "xjPkeMoMHHjFKQnIwdMHeMD7AazAPwJM//OIxDoWeKY0A9X4AMC+AbzAUgF0wC4AIak9///T++t///nP/6f/////+j/XTEFNRTMuMTAwVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV" +
        "VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVX/X6v2WaAY" +
        "EDYGJSYBlZEgabUhgf4IQYLAC/mEnhXhioBFGdaL+FmwrDZYHGtGQGdQbIKFyBoGkDCaG4DCQE0DBWD4PUR/////b///nX////OIxE8Ykn4oAK/s4P//+7//9X/z2n7en/p0//dT7eWVTEFNRTMuMTAwVVVVVVVV" +
        "VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV" +
        "VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV/2/9VRdAwAKAMNl8DFSEANK5gRgAIYKqBxmFZBIxjQI+Wevhylm8yjJoHbBLAGqcuoGYwngGM4dgGJMVYGE4NQGCcKofKgtvv6u//9uyv/t51///b/V/R///" +
        "//OIxFobXAYkAK/s4G6/p/f/0Pv///vb//v//9X+r/PKTEFNRTMuMTAwqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq" +
        "qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqof//+fBwYBq" +
        "KBxyAHigmA1AV5gJ4KMYB4FLmAlkNRhQHssYKiNYCKSzDBIDF0mzF8LwcbBQTREK//OIxDgTAKY0Aqf64K1d///p/1///If/1f//+nR//R/rTEFNRTMuMTAwqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq" +
        "qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq" +
        "qqqq9uv1fusuAYCGoGIz0BlpjgazbBgpYJgYPYDEmGrhTxj0xAyf2r2FnGwDJ4HoM9wGtAQoGU8OoGEcY4GCkWwGDwPoGCcNAZERV/9fXX/9upf/0vOt//7//+m///Xf//OIxF0cLAYgAK/s4P6Prb/zv++//+u3" +
        "//b/9vf/X/m1TEFNRTMuMTAwVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV" +
        "VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVR/q//UagYIkBnWoG2jAakmYBUApGBkghJg4ATAYi2P9nJCdS5qSYzSBvYScBnTKmBkgH8Bik" +
        "FQBiDDeBhMB8BgnBiI9Qv//v//9v/29b//OIxE4Ycn4sAqfs4H//t//7f/+v6/m2j//9KdP/9X+hTEFNRTMuMTAwVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV" +
        "VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV" +
        "VVVVVVVVVVVVVVVVVYf//+fAYDAaASBx1QHopmBDAXZgRYKIYF8FDmDLkFRmq3eIY7mM9Gm0YmJqEGDY8mJIDmMQAmJIAAIU//OIxDsTuKY0Aqf64Fob////63f/+a//o/2f/0f/+j/WTEFNRTMuMTAwqqqqqqqq" +
        "qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq" +
        "qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqv9fq/ZZgBAXgYBNgGJlWBnVVGCEgZhg1wGqYYWCYGOJBv59JLNycGkFOgeERIAargdAZWRcgYdRmgYCBWAYAA5gAheE2Lt/6///t1f/v6z3//v//6L/" +
        "//OIxFYadAYkAK/s4P/3/6f//r/3///v9v+3//3/1/5+TEFNRTMuMTAwqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq" +
        "qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqF/q/9S0i0BggQGhMgb44AyGAIDwYDWCTmCUB" +
        "QBhg5CabOV5smdDjUoGrhLQGVMo4GOAbwGIwQQGHsJYGEwEQGCkC4j0wWr6v///9//OIxEsXkYYwCKfs4L/V/rPf6P9n/9Wn//9KP/91X+Uqu+0HmeRr7KIDXg5LcmUpmOEiIhLhgAhaQyHoqEBB2IAMDIZjg8oG" +
        "aBBGeLZms4bdwmDAALZgooKgYYwCAmPakoJjP33scr6R5mA3ANRgfIFeYBkBiGCFgPJgJ4DmYCeArmAEguRhcwP4YTWJmmHOg7hiOgYgYFyC/mBhAbxgywHgYD+Bkj6cCVE2lLGi9hhhA8ZuOmCgokJmDCRiAEYg" +
        "NCQSjWIwMxgIYgnwBQlCsGgalzaN0L5237TkeRgDuuvH1cXaRStv25u82koWPQV2kQc7kVfu61yhuOnC6GXPxp35jGAJNWlsP/GJvKbn8bUs+nucqUXeU/0l3K7f52k3//OIxP9LKsIoFN/26F7nK1FnynrVLtq7" +
        "Py3tJuvrmV7P89a33do4ERM4BiOTSxinOXJpsy/sZjenuO0Fp221wD//LW9y2lym5au12YAdJFJQLkkd5hz/LJcwKAShqjGYPAOBSFNcnBMyFWOSYEBT3GAonBw3hgNggIjBUBDGsCjBwE8MU+Q06PyOTISCRMHI" +
        "AcwWgBjAzA1MCoC4HGGGCeCOVAVgqAsGBBGAOAgDgKhEA8PANAoCYyiQxk0QKxM6YoqaACSNwxiApoJBmBOCo4idF4gwkMlhIMJGlMAQJGAJWGYKgaMB1LUSWdl1lFks3mUkjM05j78JCsZYpJmarAvy0CLrDN2e" +
        "eXtsvKLQuWM5eGQSiBW4y2HLbvQVP07///OIxOVCijpZXu+1JzpZRu9DsdpJRIYZ3KMoej1abuN5DYRTqbuN5DbFI+TM15AeE0yqTEFNRTMuMTAwqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq" +
        "qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqpAALjQX/3/7z/1vmW+Zb5jcv0ty/Kak9Ko/IWtPisUGgowAHTDIkMejgzASzVqMOVTkwi0MWMYuTtzweFgwxjQM" +
        "hMFtBADAUAFcwUkFCMKqAujA8gEEwC0AAAwA6XikrWXpikPRGWS6ZsS6tfs1s7NY1pNSak0NYaw1pNSyJoaw1jWkxFKTQ1Y1//OIxIknMio1VufHKEaghplmszBqrXuj/7//q/o///++TEFNRTMuMTAwqqqqqqqq" +
        "qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq" +
        "qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqh/7/2lgACGFwiPDQZHZkpNGrYuc+/RhPIj6Y6s3RHy7Pdpj5Al8YW2E/mDRg2Jg7AOYYc2B3GC5gOJgIAAsAgBsvgpux" +
        "//OIxEUWQOIsAgc+5AfyNhm7/f/u/9XD3//////r/1/uTEFNRTMuMTAwqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq" +
        "qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqkD////6sV4BALAweKgMZDsDMhjA0SfgNlLcDpNAM" +
        "KEC7zHsUvw/aVUxMfjCmDCBgAUwA4EWMDoBxzCaQQsDfp+AxMHQMBgAMUi5jFI1N//OIxE4YYf4wBK/rIJv/////9/////ndez6dn////f6aTEFNRTMuMTAwqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq" +
        "qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq" +
        "qqqqqqqqqqqqqqqqqqqqqv/L/XIYFgOYXAUYegAYHjgYgnaZbMsat2yYVcMxGPyzn5+ptfMZDmNRmGrBoxhEQQAYUuD9mKTAfphDgDwYDSAMmAPAAAQAHoaKbuXDlOYT//OIxFAY8OYkAAd+5P6NvxN/o+h/v//+" +
        "z//7Dn9n+z5eTEFNRTMuMTAwqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq" +
        "qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqh////9eLSBEEAYCEoGIxcBlMkAZ6KoGvTsBzZnmExg+xjpBoqfSQdLGPAAzZhBIDCYCq" +
        "COmBBg2BgzwH0BqY6gYTDANoh6Q5JYPG//OIxEsXogI0Aq/rIse//////7f////OK9f//////7q6TEFNRTMuMTAwqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq" +
        "qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq/f/+r7aLw1eBgYAIAUJsDDQCsDCULsDAwVoDFOjs" +
        "DKk+4wqcjLMew2Bj69PGsyGIkAMO5EMTCtwkcw4YH8McfA7DC9QHEwJwAUAQDeEAFAYAFooMMduk3t/2083p/8hfv/r/T8M3//OIxGYeY1YcALfFJLP0/+n0//+v2/9fSv9+sfy+xv6KTEFNRTMuMTAwqqqqqqqq" +
        "qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq" +
        "qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqwD////6sXwIASASJAMNCsDJg7Az2OgNiEcDpJ6MKEBPTHpyMg/QUnJMfpAyjCPgMAwI4FAMAsByzBCwQcD0+gMIbAeAEIRnimblp" +
        "//OIxEsXuf40BK/pINv/////9////r+ZnVr2f//////TTEFNRTMuMTAwVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV" +
        "VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVX9v//t6TRHgDQNwChSgYeQhAYcRpAYGC3gYREoAYxYGmDOEiBiSO+ucPf82GKeklJh" +
        "eQgAYUcDrGHJgoJjrQDiYYgAYAYFLEgHQWALxIAIR/ZW+lf9/6f9t6/9WVP///X8//OIxGEdIf4cALfFJB6aQ98l/fT/0bvfFDvq/xMtbPl1TEFNRTMuMTAwVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV" +
        "VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV" +
        "VVVVVVVVVVVVVVVVVYA////+vFZCEFAOEoGDxMBkUVAZ4DIGyQUB1IFmFLgJhj6waefykHRGQQAKhhM4IeYF+CtmASA7BgJgIUBmv4DzgJARIhrkMJwtnn//////2/////OIxFMZkio0BK/pIvvqrQetlv50XCnu" +
        "////+n+v//vVAbnIPO4EJZ3En4feVRR2Hxb9cjkq7Zg3rE27tKVgLnqbAIEIQMeByyCMyKIGEzAiAxAFM5MzAkozwgMJfTaJE3ecOOjzgRcwhMIdMtkw4DBuc9MyfkJWDgeEwbMBFMHGAITEjQi41zGgyuCox3LE" +
        "w/LQzIHczFL41FVoHlodPwmaaTMaJKOa4hqZWDYuoFCQYcBwDANMEQLL/AIEFsqXy+RgEB0FjAoBhwAwUC5fRVjL30Zg01B9R5JBNNvmWQHAMKXY2Fe60H5a/HJVBzO2xMkXO6zLIDh2Lv49LbsogVx4hIpyNzUU" +
        "huXP5NwxflEzF4hLYfuUdjOmlkrpqSve//OIxP9M0rYkHN/7Ibesb8oxp6l/DeWFfKk3ez1zOpjnq3gLA0kxZHIWSXZDJr/IWaNs1q7rPer7X3dap6vv1/6VQLbI0jftTk7fkVWEzUmuSO3RSGVPdAL5xF8o43zf" +
        "sNUJQFKMJVIxJaoGpUAoAKMARAAjAJgE0EgBYwA1iwMyYI+BtGBJAtRjM5a0ZreWcGLzgUBgQAMAYG0BpGApgm5gqAEuYCuAcGAKABpgKwFEYHkAimCmgW5gaYJUYRqBXmGwlQxvKULEaAEFHmQLiFZhqoPgYWyC" +
        "jGGOAGRgOAIiYG4A1gYINMB7ARzAswCYwAYAuMCIAATAGAB0jhBF4S/hmYFNCbCXvJqaKQ88Hhg0gHjAsHFjbOBoo8o8PTXR//OIxN5Soto0Pv6ZhS0R1eIURdEeRpmLoWYAwZgPiAw4H4lj+I5oIkYjrx0JBYEh" +
        "GJdSYsMzNWJbpIsZtrDhwqRkupxR9fdPVJjd6MUY9vYGLt63LFIfWZME7uZu63yksZasoT7zHKWxOzLPAHcshMIc7mt7/3+79bUYAKIneOOXd46y1l3HmWW6XdnCt2rZuU2qbOU2ZVLpl/Zt/Zx2pE4LTXwQeYUq" +
        "ZSRgAgAiQABBgAAAqYTKCRGDHgSBgqgJGYKUEzmBYjcBoHd5iYBYDMHMrxHVpAnZzYmVJbGOJ0GLwsGM4xGPIVGFQkmHwNhcIDC0HobYbPuTFYlD1DGakasSq0FAYBOAmFEwVVRiZquxqdWNqTFGqkCOtfY1KFtq" +
        "//OIxKYv+qI0Hv9HZFDUVVJjUtYZqRnW1IMOXXXekNa+z/7v//bQTEFNRTMuMTAwqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq" +
        "qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqrGn////6e3UoQjUUgcUmHACBgH" +
        "oAaYacCWEwYoYG6A2GBHg0xgHY/yaC764GCfhaZi6LGBUiACkYDF5ggKAoEDwHXB//OIxEMVsQ4sAlf5QCdP////bR+/79nee7FG///0f/+qTEFNRTMuMTAwqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq" +
        "qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq" +
        "qqqqqqqqqqqqqqqqqqpGv/X///N/0I0LheANpEGADgApgGwCEYYeF5mCzgNJgWQBSYAsC0mC5Dqhz1XG6Ya4FLAbNfoGVEEBi0lgYcFgGFw2BgkBgNAQRuVL2/9f//////OIxFIZeqosAlfrQP/9Xv/+3v//9t57" +
        "rsd3f/Ru///TTEFNRTMuMTAwVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV" +
        "VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVxf////i9f/eHaj7rkLrmADACxgGoD2YXMJnGCnAbBgRIAuYDYCWGFOjc5/8+wUYs" +
        "WE2naHQalO5lwjGOxeYmERg4GAoFrony//OIxEgW6Q4oAA/5JD//6//0fvo7v3n+xSej/99H//96TEFNRTMuMTAwqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq" +
        "qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq" +
        "qqqG3////7f6OWIRIAfSMCoAmYAcA3GDCiM5gUIGmYAsAmGBRgMphPQc4fVs6PmKOAnAHUTSBpgXAZTDYGMAgBhkIgYBAoWg//OIxEYWSfIwAlfrQguc0Vv1////////ns/0Sv/9XXRVTEFNRTMuMTAwVVVVVVVV" +
        "VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV" +
        "VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVWQN/////3/3Y2JIaQ+JLjAAoFQHcwIgS8MAcA7jAKAHswOAA3MLBBMz/MS0oxYkBVO4AgHVcFLgxqATDAIAgES" +
        "//OIxEAVAQowBG/5QK3gFv///+ms58t/+lH2t//////oTEFNRTMuMTAwVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV" +
        "VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVxt////+3+yRq" +
        "SIxg6p3DgAmFQHQwMYSxMBkA9TAcQJgwQUDCMLICMT+lkDQxYADBO4kQ1UGQEuiY//OIxDkTIQowAm/5QMAGE4XAKskAhT////9v1/T/T9rFTEFNRTMuMTAwVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV" +
        "VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV" +
        "VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVhv////8///LGmjT6tKT1C4AcYAgAzmDXiIBgaIHIYFEBUmCJAkZhS4iQfHbA8mKCgwB1JJmnSIZS//OIxDkTKRIwAg/5JA6BikNAxNxSlyrO" +
        "v///+rZ9X/9STEFNRTMuMTAwqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq" +
        "qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqsH/P///F6/+NaMv65S7UJRgAgAiYBqA2GGGCPpgvQIGYIOBwGCvg6xhbA8GfghyIGKqBVoHb4YBqpFg" +
        "ZZJAGKA6DY0GXQbnCAJWVv2////6v//9//OIxFMZiqooAA/rJB9f/6//t/+vNemlnf/9NX1f/ZTVTEFNRTMuMTAwVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV" +
        "VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV" +
        "VVVVVVVVVVVVVYY/////1//6q00PPy05S0DABxgGwBiYZCFHGC+gThgeAFeYIQDfmDfj0RxdPTGYYyFbG0oeZdRRigmmBxIS//OIxD4UcQ4sAg/5JIFULQhX9IWfs///z0t+c//v9SOlTEFNRTMuMTAwVVVVVVVV" +
        "VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV" +
        "VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVXGn////7+3UoQiyFoIVGSgARDgHow1ICNMGQAPzA6wIowMUG8MCwICzI4vcwwNQLbMcxwwkkwaUh0WgAIBgAKAOuGT" +
        "//OIxEMVoRIsAlf5QOv///+vd8ve7Tq7VfY/v/////6FTEFNRTMuMTAwVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV" +
        "VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVXX////8z/QqhMJgEaa" +
        "gKAEzAOgCQwz8HxMGBAJTAzgFUwGYGVMDGHzDaavEMwigLCM6xExQjDCZRMGC4we//OIxD0UIQ4sAFf5QBcBA8WAjF6Ign////Of7v/53tmFTEFNRTMuMTAwVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV" +
        "VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV" +
        "VVVVVVVVVVVVVVVVVVXL//y//n6/+dSvYf9diAcwAoAOMA/AYzDTg/wwYICiMC5ACjACgXYwhEfjPUr9SjEkwskDkEOA0CjQMjFQDF41AxAIgMHAgA4Hh0hXU3/////b//OIxFIZWqooAA/rJP//1+3/7////2n+" +
        "qSfr//7///0qTEFNRTMuMTAwqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq" +
        "qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqhm/////p/sexUKAAehgAQBUwCIByMJFEkzA/wNMwFYAwMCFA0zChhWI/OiqJ" +
        "MVKB3jrKvNOFYyuMzGggMPhkwSCS0DL7//OIxEUWMQ4sAlf5QAhFf///7Kf3fd+452rR//+n//++TEFNRTMuMTAwqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq" +
        "qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqpA3////" +
        "////z/////iEVa+l4jKYAWABgUAJIAGQwMgCyMFuEajBshFYxNYNWMUrIjzL+SSk/ANzwMg2HvjEBgGMwW8DpMD7BKQECzo+//OIxE0YQQ4wBUH4ALKhUAdAwBu65/////vlPz3/7jvrXr8eEcUPmDWj4IhIPOZF" +
        "YfuW5b9/uaZezBkigiYjBDAAQAH9QD6gib6FYBAATABQAkMACzASAHAwIEHrMcJBjqqE4wBUA0MBCCzTEkAjIcAEDAHAAowBIAoMBsA2zBBg8kx2Ll/NAjHpzA3gbYwHoBOMAsAGgcAMGibCHBteIV8YPsBcGAJA" +
        "D5gCQACYAAAEmR0oFhm3IsIYLwBYmAgAEwwAQmAPgAJgBYAGXHWuoIxB+HLUqU2S+dFyWsxIEgAaRwcAALQaSrt43/l8Yllinp88IedqZlsM1qaNVX+cSDJa/cdl0OTWHM8//nP//paXK1TbxpdZZbsy+rfpK16n" +
        "//OIxP9L6x40AYz4AKt+ky/+fl3/1/7/8McdZa3zmu9/nPsW8b+FqxnjnhawEsfZNdDEf4WAhI+BEHwIgP1MQU1FMy4xMDBVVBVqGoay0UxbidMrchyHK66dIKPSqlyaJoqGAX4QoNU/MBLDLGa9K05QIAmAALJl" +
        "VSyoCAUNVOjBRIx0iMjIjCgEdCjJz41NgNlWjRRoCHZtESc1Wm+wBtq4aegGXighATFBsxYHRkMNDFBDDRoyMmMnIjHxYw8AYmAAkwwNLXPukKgFQdXTKFMkVmWyh2mdM6d6ndlnMPZxl/X9jOEqf6W4U0qjUu7V" +
        "jNN3GlpaXlamx5lWprTYN4KC5G8Cjo3xQV3+FDfG4gor3ZBT/8FBfN4FHQngoL0V//OIxNg66e4MA8/YAZBR2T4oL0F8KOhHYgvivCjsjugqTEFNRTMuMTAwqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq" +
        "qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq" +
        "qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"
        ) ?? Data()

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
            handleMicChunk(caps)
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

    /// Reassemble the microphone uplink (route `0x3002` inbound): `uBuk`
    /// chunks whose binary member is a slice of one Ogg-Opus byte stream
    /// (OpusHead first, 16 kHz mono — mined from the 2026-11-21 capture).
    /// Concatenated in arrival order they form a saveable `.opus` file.
    /// A clip completes when the stream goes quiet for 3 s or the AI scene
    /// closes; chunks are counted, not traced (~25 a second while listening).
    private func handleMicChunk(_ caps: [RokidCapsValue]) {
        audioChunksReceived += 1
        guard caps.count > 1, case .binary(let data) = caps[1] else { return }
        onAudioChunk?(data)
        if micAssembly.isEmpty {
            micChunksReceived = 0
            let magic = data.prefix(4).map { String(format: "%02x", $0) }.joined(separator: " ")
            trace("RX mic stream started: first chunk \(data.count) B [\(magic)]")
        }
        micAssembly.append(data)
        micChunksReceived += 1
        armMicQuietFinalizer()
    }

    private func armMicQuietFinalizer() {
        micGeneration += 1
        let generation = micGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, generation == self.micGeneration else { return }
            self.completeMicClip(reason: "stream quiet")
        }
    }

    /// Close out the in-flight mic assembly, if any. Also called when the
    /// AI scene closes — the listen window is over either way.
    private func completeMicClip(reason: String) {
        guard !micAssembly.isEmpty else { return }
        micGeneration += 1
        let clip = micAssembly
        micAssembly = Data()
        lastMicClip = clip
        trace("RX mic clip complete: \(clip.count) B in \(micChunksReceived) chunks (\(reason))")
        onMicClip?(clip)
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
                    if !running { completeMicClip(reason: "scene closed") }
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

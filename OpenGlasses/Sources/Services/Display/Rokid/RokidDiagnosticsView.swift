import AVFoundation
import Combine
import ExternalAccessory
import Foundation
import SwiftUI
import UIKit

/// A deliberately plain hardware probe for the RV101 command path.
///
/// Nothing here is product code. Since 2026-11-21 the probe sits on top of
/// ``RokidCXRSession``, which owns the registration hello, the sequence counter, the
/// inbound decoding and the answer choreography; what remains here is the operator's
/// window onto that layer — the accessory listing, a log fed by the session's trace,
/// and senders for hand-built commands and raw bytes. It can still be deleted without
/// touching the session layer.
@MainActor
final class RokidDiagnosticsModel: ObservableObject {
    @Published private(set) var accessoryLines: [String] = []
    @Published private(set) var entries: [String] = []

    @Published var rawHexText = ""
    @Published var channel = "Dev"
    @Published var method = "Dev_GetGlassInfo"
    @Published var payloadText = ""
    /// Text the AI-answer demo displays on the glasses.
    @Published var demoText = "Hello from Avenkin"
    /// Where the last saved photo buffer landed, once one has been saved.
    @Published private(set) var photoBufferURL: URL?
    /// Where the last saved mic clip landed, once one has been saved.
    @Published private(set) var micClipURL: URL?
    /// The on-device transcript of the last mic clip, once transcribed.
    @Published private(set) var micTranscript: String?
    /// The app's own SenseVoice engine, reused across taps (model loads lazily).
    private let asrEngine = OnDeviceASREngine()

    /// The relay's shared token, pasted once by the operator and kept in
    /// UserDefaults — never in source.
    @Published var relayToken: String = UserDefaults.standard.string(forKey: "avenkin.relayToken") ?? "" {
        didSet { UserDefaults.standard.set(relayToken, forKey: "avenkin.relayToken") }
    }
    /// Remy's latest answer, once the relay delivers it.
    @Published private(set) var relayAnswer: String?
    /// True while a question is out and no answer has landed yet.
    @Published private(set) var relayWaiting = false
    /// An answer that arrived while the AI scene was closed, held until the
    /// scene next opens (the lens only renders inside the scene).
    private var pendingPresentation: (question: String, answer: String, audio: Data?)?
    /// Watches the session's scene state so a held answer presents itself
    /// the moment the wearer reopens the scene.
    private var sceneCancellable: AnyCancellable?

    /// Whether the bundled Remy card flow is armed: while armed, every
    /// completed mic clip is transcribed and asked automatically.
    @Published private(set) var cardActive = false
    /// The card's live status line.
    @Published private(set) var cardStatus = "Off"

    /// The session layer this probe operates, exposed so the view can observe the
    /// session's own published state (registration, scene, screen, battery) directly.
    let session: RokidCXRSession

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    init(session: RokidCXRSession) {
        self.session = session
        session.onTrace = { [weak self] line in
            Task { @MainActor in self?.append(line) }
        }
        sceneCancellable = session.$aiSceneActive.sink { [weak self] active in
            guard active else { return }
            Task { @MainActor in self?.presentPendingAnswer() }
        }
        session.onMicClip = { [weak self] _ in
            Task { @MainActor in await self?.handleCardClip() }
        }
    }

    // MARK: - Accessories

    func refreshAccessories() {
        var lines: [String] = []
        let accessories = EAAccessoryManager.shared().connectedAccessories
        lines.append("\(accessories.count) EAAccessory object(s) visible to this app")

        if accessories.isEmpty {
            lines.append("Nothing connected. Check, in order: glasses powered on and paired in")
            lines.append("Settings > Bluetooth; Rokid's own app force-quit; the MFi protocol")
            lines.append("strings declared in Info.plist under UISupportedExternalAccessoryProtocols.")
        }

        for accessory in accessories {
            let advertised = accessory.protocolStrings.sorted()
            let matched = RokidMFITransport.matchingProtocols(for: accessory)
            lines.append("• \(accessory.name)")
            lines.append("    serial \(accessory.serialNumber)  fw \(accessory.firmwareRevision)  hw \(accessory.hardwareRevision)")
            lines.append("    manufacturer \(accessory.manufacturer)  model \(accessory.modelNumber)")
            lines.append("    advertises [\(advertised.joined(separator: ", "))]")
            lines.append(matched.isEmpty
                         ? "    ✗ no Rokid protocol advertised — EASession cannot be opened"
                         : "    ✓ matches \(matched.joined(separator: ", "))")
        }

        accessoryLines = lines
        append("refreshed: \(accessories.count) accessory object(s)")
    }

    // MARK: - Session

    func toggleConnection() async {
        if session.isConnected {
            session.disconnect()
            append("disconnected by operator")
            return
        }
        append("opening EASession via RokidCXRSession (rawCaps)")
        do {
            try await session.connect()
            append(session.isConnected ? "EASession open" : "connect() returned without a session")
        } catch {
            append("connect failed: \(String(describing: error))")
        }
    }

    // MARK: - Commands

    /// The safest first command: a status read the glasses answer without changing state.
    func probe() async {
        do {
            try await session.getGlassInfo()
        } catch {
            append("probe failed: \(String(describing: error))")
        }
    }

    /// Fire the session layer's paced answer choreography. The scene it renders into is
    /// opened by the glasses themselves — the wearer says the wake word ("Hi Rokid")
    /// and the glasses send `Ai_SceneStatus` with `aiAssistRunning` true — so tap this
    /// within a few seconds of that.
    func sendAIAnswerDemo() async {
        await session.presentAnswer(question: "Who is Avenkin?", answer: demoText)
    }

    /// Ask the glasses for a still; the reassembled photo lands in the session's
    /// `lastPhoto`, and the log traces the transfer's start and completion.
    func takePhoto() async {
        await session.takePhoto()
    }

    func openCamera() async {
        await session.openCamera()
    }

    func playTestTone() async {
        await session.playTestTone()
    }

    func playSpokenTest() async {
        await session.playSpokenTest()
    }

    /// Whether the scene-hold experiment is running.
    @Published private(set) var sceneHoldActive = false
    private var sceneHoldTask: Task<Void, Never>?

    /// Scene-hold experiment: heartbeat every 2 s and log the scene state
    /// every ~10 s, to learn whether the phone can keep the glasses' AI
    /// scene open past its usual idle close. Caps itself at five minutes.
    func toggleSceneHold() {
        if sceneHoldActive {
            sceneHoldTask?.cancel()
            sceneHoldTask = nil
            sceneHoldActive = false
            append("scene hold: stopped by operator")
            return
        }
        sceneHoldActive = true
        append("scene hold: started, heartbeat every 2 s")
        sceneHoldTask = Task { [weak self] in
            var beats = 0
            while !Task.isCancelled {
                guard let self else { return }
                try? await self.session.sendHeartbeat()
                beats += 1
                if beats % 5 == 1 {
                    let state = self.session.aiSceneActive ? "active" : "idle"
                    self.append("scene hold: beat " + String(beats) + ", scene " + state)
                }
                if beats >= 150 {
                    self.append("scene hold: five-minute cap reached, stopping")
                    self.sceneHoldActive = false
                    return
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    /// Save the session's raw in-flight photo assembly to the app's Documents
    /// folder, for offline dissection of the media-sync stream's structure.
    func savePhotoBuffer() {
        let data = session.photoAssemblySnapshot
        guard !data.isEmpty else {
            append("photo buffer: nothing assembled right now")
            return
        }
        let name = "avenkin-photo-buffer-\(Int(Date().timeIntervalSince1970)).bin"
        do {
            // Temporary directory + the share sheet: the app's Documents folder
            // is not exposed to the Files app (no file-sharing flag in the
            // Info.plist), so a file saved there is unreachable for sharing.
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try data.write(to: url)
            photoBufferURL = url
            append("photo buffer saved: \(name) (\(data.count) B) — tap Share photo buffer")
        } catch {
            append("photo buffer save failed: \(String(describing: error))")
        }
    }

    /// Save the session's last completed mic clip (Ogg-Opus) to a shareable
    /// file, for offline decode and verification.
    func saveMicClip() {
        guard let clip = session.lastMicClip, !clip.isEmpty else {
            append("mic clip: nothing captured yet")
            return
        }
        let name = "avenkin-mic-\(Int(Date().timeIntervalSince1970)).opus"
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try clip.write(to: url)
            micClipURL = url
            append("mic clip saved: \(name) (\(clip.count) B) — tap Share mic clip")
        } catch {
            append("mic clip save failed: \(String(describing: error))")
        }
    }

    /// Transcribe the last mic clip on-device, through the app's own
    /// SenseVoice engine. The clip is Ogg-Opus; AVAudioFile gets first
    /// refusal on decoding it — if this iOS build's AVFoundation cannot
    /// open Opus, the failure is logged plainly and the decode gap is the
    /// next problem to solve.
    func transcribeMicClip() async {
        guard let clip = session.lastMicClip, !clip.isEmpty else {
            append("transcribe: no mic clip yet")
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("avenkin-mic-transcribe.opus")
        do {
            try clip.write(to: url)
            let (samples, rate) = try Self.decodeSamples(url: url)
            append("transcribe: decoded \(samples.count) samples @ \(Int(rate)) Hz")
            guard OnDeviceASREngine.isCompiledIn else {
                append("transcribe: on-device ASR not compiled into this build")
                return
            }
            guard asrEngine.isReady else {
                append("transcribe: SenseVoice model not downloaded yet — grab it in the app's ASR settings, then retry")
                return
            }
            let text = try await asrEngine.transcribe(samples: samples, sampleRate: rate)
            micTranscript = text
            append(text.isEmpty ? "transcript: (empty)" : "transcript: \(text)")
        } catch {
            append("transcribe failed: \(String(describing: error))")
        }
    }

    // MARK: - Relay (the Remy front door)

    /// Send the current transcript (plus the latest photo, when one exists)
    /// to the relay at relay.apsisai.com and poll for Remy's answer. The
    /// answer shows in the probe the moment it lands; it renders on the lens
    /// right away if the AI scene is open, or when the scene next opens.
    func askRemy() async {
        guard let question = micTranscript, !question.isEmpty else {
            append("relay: transcribe a mic clip first")
            return
        }
        let token = relayToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            append("relay: paste the relay token first")
            return
        }
        guard !relayWaiting else {
            append("relay: already waiting on an answer")
            return
        }
        relayWaiting = true
        relayAnswer = nil
        do {
            var payload: [String: Any] = ["text": question]
            if let photo = session.lastPhoto {
                payload["photo"] = "data:image/jpeg;base64," + photo.base64EncodedString()
            }
            var request = URLRequest(url: URL(string: "https://relay.apsisai.com/ask")!)
            request.httpMethod = "POST"
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                append("relay: ask failed, HTTP " + String(code))
                relayWaiting = false
                return
            }
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let id = obj?["id"] as? String else {
                append("relay: ask returned no id")
                relayWaiting = false
                return
            }
            append("relay: question sent, waiting for Remy")
            await pollForAnswer(id: id, question: question, token: token)
        } catch {
            append("relay: ask failed: " + String(describing: error))
            relayWaiting = false
        }
    }

    /// Poll the relay for one question's answer, every 3 s for up to four
    /// minutes, then present it.
    private func pollForAnswer(id: String, question: String, token: String) async {
        let answerURL = URL(string: "https://relay.apsisai.com/answer/" + id)!
        for _ in 0..<80 {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            do {
                var request = URLRequest(url: answerURL)
                request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
                let (data, _) = try await URLSession.shared.data(for: request)
                let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                if (obj?["status"] as? String) == "answered", let text = obj?["text"] as? String {
                    relayAnswer = text
                    relayWaiting = false
                    append("remy: " + text)
                    var audio: Data? = nil
                    if let audioPath = obj?["audio_url"] as? String, let audioURL = URL(string: audioPath) {
                        audio = await downloadAnswerAudio(url: audioURL, token: token)
                    }
                    pendingPresentation = (question, text, audio)
                    presentPendingAnswer()
                    return
                }
            } catch {
                continue
            }
        }
        relayWaiting = false
        append("relay: no answer after four minutes, giving up the wait")
    }

    /// Fetch an answer's voice (MP3) from the relay.
    private func downloadAnswerAudio(url: URL, token: String) async -> Data? {
        do {
            var request = URLRequest(url: url)
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty else {
                append("relay: answer voice download failed")
                return nil
            }
            append("relay: answer voice downloaded, " + String(data.count) + " B")
            return data
        } catch {
            append("relay: answer voice download failed")
            return nil
        }
    }

    /// Isolation test: download a fixed fixture MP3 from the relay and
    /// stream it as an utterance's voice, bypassing the ask/answer flow.
    /// kind "chirp" fetches the exact bytes of the embedded test chirp;
    /// kind "voice" fetches a synthesized spoken sentence.
    func voiceDownloadTest(kind: String) async {
        let id = kind == "chirp"
            ? "11111111-2222-3333-4444-555555555555"
            : "66666666-7777-8888-9999-000000000000"
        let token = relayToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            append("voice test: paste the relay token first")
            return
        }
        guard let url = URL(string: "https://relay.apsisai.com/audio/" + id) else { return }
        append("voice test: downloading " + kind)
        guard let data = await downloadAnswerAudio(url: url, token: token) else { return }
        append("voice test: streaming " + kind + ", " + String(data.count) + " B")
        await session.speakDownloaded(mp3: data)
    }

    /// Render a held answer on the lens if the AI scene is open. Called when
    /// an answer lands and whenever the scene opens. With a voice attached,
    /// the answer is spoken as well as shown.
    private func presentPendingAnswer() {
        guard let pending = pendingPresentation, session.aiSceneActive else { return }
        pendingPresentation = nil
        if let audio = pending.audio {
            Task { await session.speakAnswer(question: pending.question, answer: pending.answer, mp3: audio) }
        } else {
            Task { await session.presentAnswer(question: pending.question, answer: pending.answer) }
        }
    }

    // MARK: - Remy card (the bundled flow)

    /// Arm or disarm the bundled card flow.
    func toggleCard() {
        cardActive.toggle()
        cardStatus = cardActive ? "Say Hi Rokid and ask your question" : "Off"
        append(cardActive ? "card: armed" : "card: off")
    }

    /// While the card is armed, a completed mic clip runs the pipeline by
    /// itself: transcribe, then ask. The recognizer's guard returns empty
    /// text for silence, and an empty transcript never becomes a question.
    private func handleCardClip() async {
        guard cardActive, !relayWaiting else { return }
        cardStatus = "Transcribing..."
        await transcribeMicClip()
        guard cardActive else { return }
        if let text = micTranscript, !text.isEmpty {
            cardStatus = "Asking Remy..."
            await askRemy()
            if cardActive {
                cardStatus = session.aiSceneActive ? "Answered" : "Answered - say Hi Rokid to see it on the lens"
            }
        } else {
            cardStatus = "Heard nothing - ask again"
        }
    }

    /// Decode an audio file to mono Float samples via AVAudioFile.
    private static func decodeSamples(url: URL) throws -> ([Float], Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw ASRError.recognitionFailed
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else {
            throw ASRError.recognitionFailed
        }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        return (samples, format.sampleRate)
    }

    func sendComposedCommand() async {
        let trimmedPayload = payloadText.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload: RokidCapsValue? = trimmedPayload.isEmpty ? nil : guessPayload(trimmedPayload)
        do {
            try await session.sendCommand(channel: channel, method: method, payload: payload)
        } catch {
            append("send failed: \(String(describing: error))")
        }
    }

    func sendRawHex() async {
        guard let bytes = parseHex(rawHexText), !bytes.isEmpty else {
            append("raw hex: nothing usable to send")
            return
        }
        do {
            try await session.sendRaw(bytes)
        } catch {
            append("raw send failed: \(String(describing: error))")
        }
    }

    // MARK: - Log

    func append(_ line: String) {
        entries.insert("\(Self.clockFormatter.string(from: Date()))  \(line)", at: 0)
        if entries.count > 400 {
            entries.removeLast(entries.count - 400)
        }
    }

    func clearLog() {
        entries.removeAll()
    }

    var logText: String {
        entries.reversed().joined(separator: "\n")
    }

    // MARK: - Helpers

    /// JSON object, bare integer, or plain text — whichever the typed payload most resembles.
    private func guessPayload(_ text: String) -> RokidCapsValue {
        if text.hasPrefix("{") || text.hasPrefix("[") { return .string(text) }
        if let value = Int32(text) { return .int32(value) }
        if let value = UInt32(text) { return .uint32(value) }
        return .string(text)
    }

    private func parseHex(_ text: String) -> [UInt8]? {
        let digits = text.filter { $0.isHexDigit }
        guard !digits.isEmpty, digits.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(digits.count / 2)
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            guard let byte = UInt8(digits[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}

/// Drop this in wherever you want a hardware probe; it has no dependencies beyond the
/// session layer, so it can be deleted again without touching anything else.
struct RokidDiagnosticsView: View {
    @StateObject private var session: RokidCXRSession
    @StateObject private var model: RokidDiagnosticsModel

    init() {
        let session = RokidCXRSession()
        _session = StateObject(wrappedValue: session)
        _model = StateObject(wrappedValue: RokidDiagnosticsModel(session: session))
    }

    var body: some View {
        NavigationStack {
            List {
                cardSection
                accessoriesSection
                sessionSection
                commandSection
                rawSection
                logSection
            }
            .navigationTitle("Rokid probe")
            .navigationBarTitleDisplayMode(.inline)
            .task { model.refreshAccessories() }
        }
    }

    private var cardSection: some View {
        Section("Remy") {
            Button(model.cardActive ? "Deactivate card" : "Activate card") {
                model.toggleCard()
            }
            Text(model.cardStatus)
                .font(.system(.caption, design: .default))
            if let transcript = model.micTranscript {
                Text(transcript)
                    .font(.system(.caption, design: .default))
                    .foregroundStyle(.secondary)
            }
            if let answer = model.relayAnswer {
                Text("Remy: " + answer)
                    .font(.system(.caption, design: .default))
            }
            Text("While the card is active: say the wake word, ask out loud, and the rest runs itself — transcribe, ask, and the answer on the lens when the scene reopens.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var accessoriesSection: some View {
        Section("Accessories") {
            ForEach(model.accessoryLines.indices, id: \.self) { index in
                Text(model.accessoryLines[index])
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            Button("Refresh accessory list") { model.refreshAccessories() }
        }
    }

    private var sessionSection: some View {
        Section("Session") {
            HStack {
                Text("Sequence")
                Spacer()
                Text("\(session.nextSequence)")
                    .font(.system(.caption, design: .monospaced))
            }
            HStack {
                Text("Registered")
                Spacer()
                Text(session.isRegistered ? "yes" : "no")
                    .font(.system(.caption, design: .monospaced))
            }
            HStack {
                Text("AI scene")
                Spacer()
                Text(session.aiSceneActive ? "active" : "idle")
                    .font(.system(.caption, design: .monospaced))
            }
            HStack {
                Text("Screen")
                Spacer()
                Text(session.screenOn.map { $0 ? "on" : "off" } ?? "-")
                    .font(.system(.caption, design: .monospaced))
            }
            HStack {
                Text("Battery")
                Spacer()
                Text(session.batteryLevel.map { "\($0)%" } ?? "-")
                    .font(.system(.caption, design: .monospaced))
            }
            HStack {
                Text("Photo")
                Spacer()
                Text(session.lastPhoto.map { "\($0.count) B (\(session.photoChunksReceived) chunks)" } ?? (session.photoChunksReceived > 0 ? "receiving… \(session.photoChunksReceived) chunks" : "-"))
                    .font(.system(.caption, design: .monospaced))
            }
            HStack {
                Text("Mic")
                Spacer()
                Text(session.lastMicClip.map { "\($0.count) B (\(session.micChunksReceived) chunks)" } ?? (session.micChunksReceived > 0 ? "receiving… \(session.micChunksReceived) chunks" : "-"))
                    .font(.system(.caption, design: .monospaced))
            }
            if let transcript = model.micTranscript {
                Text(transcript)
                    .font(.system(.caption, design: .default))
            }
            if let answer = model.relayAnswer {
                Text("Remy: " + answer)
                    .font(.system(.caption, design: .default))
            }
            if let photo = session.lastPhoto, let image = UIImage(data: photo) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 240)
            }
            Button(session.isConnected ? "Disconnect" : "Open EASession") {
                Task { await model.toggleConnection() }
            }
            HStack {
                Text("Received").font(.caption)
                Spacer()
                Text("\(session.bytesIn) B in, \(session.bytesOut) B out")
                    .font(.system(.caption, design: .monospaced))
            }
        }
    }

    private var commandSection: some View {
        Section("Commands") {
            Button("Probe (Dev_GetGlassInfo)") {
                Task { await model.probe() }
            }
            Text("Runs through the CXR session layer, which registers on connect before any command is served. The framing question this probe used to test by hand is settled — bare Caps on the session; see docs/rokid-hardware-validation.md.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            TextField("Channel", text: $model.channel)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Method", text: $model.method)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Payload (JSON, number, or empty)", text: $model.payloadText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Send composed command") {
                Task { await model.sendComposedCommand() }
            }
            TextField("AI answer text", text: $model.demoText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Send AI answer demo") {
                Task { await model.sendAIAnswerDemo() }
            }
            Text("Say \"Hi Rokid\" first so the glasses open the AI scene — watch for AI scene: active above, or Ai_SceneStatus in the log — then tap this within a few seconds.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button("Open camera (Ai_OpenCamera)") {
                Task { await model.openCamera() }
            }
            Button("Take photo (Ai_TakePhoto)") {
                Task { await model.takePhoto() }
            }
            Button("Play test tone (playAudio)") {
                Task { await model.playTestTone() }
            }
            Button("Play spoken test (TTS + tone)") {
                Task { await model.playSpokenTest() }
            }
            Button("Voice test 1: downloaded chirp") {
                Task { await model.voiceDownloadTest(kind: "chirp") }
            }
            Button("Voice test 2: downloaded voice") {
                Task { await model.voiceDownloadTest(kind: "voice") }
            }
            Text("Isolation ladder: open the AI scene first, then tap. Test 1 streams the proven chirp bytes fetched from the relay; test 2 streams a synthesized sentence the same way.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button(model.sceneHoldActive ? "Stop scene hold" : "Hold scene (heartbeat)") {
                model.toggleSceneHold()
            }
            Text("Experiment: heartbeats every 2 s while the AI scene is open. Say the wake word, start the hold, then wait and watch whether AI scene stays active past its usual close.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button("Save photo buffer") {
                model.savePhotoBuffer()
            }
            if let url = model.photoBufferURL {
                ShareLink(item: url) {
                    Text("Share photo buffer")
                }
            }
            Button("Save mic clip") {
                model.saveMicClip()
            }
            Button("Transcribe mic clip") {
                Task { await model.transcribeMicClip() }
            }
            TextField("Relay token", text: $model.relayToken)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button(model.relayWaiting ? "Waiting for Remy..." : "Ask Remy") {
                Task { await model.askRemy() }
            }
            .disabled(model.relayWaiting || model.micTranscript == nil)
            Text("Sends the transcript above (and the latest photo, if any) to relay.apsisai.com. The answer appears here and on the lens: right away if the AI scene is open, otherwise the next time the scene opens.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let url = model.micClipURL {
                ShareLink(item: url) {
                    Text("Share mic clip")
                }
            }
            Text("The photo streams back in 480 B chunks — watch the log for the transfer start and \"photo complete\", and the Photo row in Session. Whether OpenCamera must come first is unproven; try Take photo alone first.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var rawSection: some View {
        Section("Raw bytes") {
            TextField("hex, e.g. ff5a0032…", text: $model.rawHexText, axis: .vertical)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(2...5)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Send raw bytes through the session") {
                Task { await model.sendRawHex() }
            }
            Text("Goes through the session's transport, so the rawCaps policy applies: a full ff 5a frame is stripped to its Caps blob.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var logSection: some View {
        Section("Log (\(model.entries.count))") {
            HStack {
                Button("Clear") { model.clearLog() }
                Spacer()
                Button("Copy") { UIPasteboard.general.string = model.logText }
            }
            if model.entries.isEmpty {
                Text("Nothing yet.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.entries.indices, id: \.self) { index in
                Text(model.entries[index])
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }
}

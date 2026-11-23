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

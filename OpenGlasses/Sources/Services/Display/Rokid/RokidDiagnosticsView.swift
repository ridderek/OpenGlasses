import Combine
import ExternalAccessory
import Foundation
import SwiftUI
import UIKit

/// A deliberately plain hardware probe for the RV101 command path.
///
/// Nothing here is product code. It exists to answer three questions that no capture can
/// answer on its own, because every capture we have starts after the session was already
/// established:
///
/// 1. Does iOS surface the accessory at all, and under which protocol string?
/// 2. What framing the accessory accepts. (Answered: bare Caps — see RokidMFIFraming.)
///    The toggle stays so a different accessory can be probed.
/// 3. What session id (frame bytes 9-10) does a fresh connection use?
///
/// Every byte written and read is logged in hex so a failed probe is still evidence.
@MainActor
final class RokidDiagnosticsModel: ObservableObject {
    @Published private(set) var accessoryLines: [String] = []
    @Published private(set) var entries: [String] = []
    @Published private(set) var isConnected = false
    @Published private(set) var bytesIn = 0
    @Published private(set) var bytesOut = 0
    @Published private(set) var sequence: UInt32 = 1

    /// Which payload policy the transport applies. `.framed` writes `ff 5a …`; `.rawCaps`
    /// writes only the Caps blob inside it.
    @Published var useRawCaps = true
    @Published var sessionIDText = "1"
    @Published var rawHexText = ""
    @Published var channel = "Dev"
    @Published var method = "Dev_GetGlassInfo"
    @Published var payloadText = ""
    /// Text the AI-answer demo displays on the glasses.
    @Published var demoText = "Hello from Avenkin"

    private var transport: RokidMFITransport?
    /// Per-connection UUID carried by the CXR connect hello; regenerated on each connect.
    private var helloUUID = UUID()
    private let clock = DispatchTime.now()
    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    var framing: RokidMFIFraming { useRawCaps ? .rawCaps : .framed }

    var framingName: String { useRawCaps ? "rawCaps" : "framed" }

    var sessionID: UInt16 {
        let trimmed = sessionIDText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("0x") {
            return UInt16(trimmed.dropFirst(2), radix: 16) ?? 0x0001
        }
        return UInt16(trimmed) ?? 0x0001
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
        if isConnected {
            transport?.disconnect()
            transport = nil
            isConnected = false
            append("disconnected by operator")
            return
        }
        await connect()
    }

    private func connect() async {
        let transport = RokidMFITransport()
        transport.framing = framing

        // The transport calls these from the stream thread, so hop back before touching UI.
        transport.onEvent = { [weak self] bytes in
            Task { @MainActor in self?.handleInbound(bytes) }
        }
        transport.onDisconnect = { [weak self] error in
            Task { @MainActor in
                self?.isConnected = false
                let reason = error.map { String(describing: $0) } ?? "closed by the accessory"
                self?.append("disconnected: \(reason)")
            }
        }

        self.transport = transport
        append("opening EASession with framing \(framingName), session id \(hex4(sessionID))")

        do {
            try await transport.connect()
            isConnected = transport.isConnected
            append(isConnected ? "EASession open" : "connect() returned without a session")
            if isConnected {
                // A fresh connection restarts the Caps sequence counter, and the CXR
                // hello goes out first — the official app sends it ~1 ms after its
                // session start, before any command.
                sequence = 1
                helloUUID = UUID()
                await sendHello()
            }
        } catch {
            isConnected = false
            append("connect failed: \(String(describing: error))")
        }
    }

    // MARK: - Commands

    /// The safest first command: a status read the glasses answer without changing state.
    func probe(_ wanted: RokidMFIFraming) async {
        guard let transport, isConnected else {
            append("not connected — probe skipped")
            return
        }
        let previous = transport.framing
        transport.framing = wanted
        append("--- probing with \(wanted == .rawCaps ? "rawCaps" : "framed") ---")
        await send(channel: "Dev", method: "Dev_GetGlassInfo", payload: nil, framing: wanted)
        transport.framing = previous
        append("--- probe finished; watching for a reply ---")
    }

    /// The CXR connect hello, decoded from the 2026-11-21 cold-connect capture: a
    /// seven-member tuple on route 0x1004 — `(route, sequence, 15, uuid,
    /// nanosecondsSinceEpoch, eapProtocolID, "")`. The glasses answer on route 0x1005
    /// with `(route, sequence, 15, status, phoneBluetoothAddress)`; until this exchange
    /// happens the CXR service ignores every command sent on the session. Member 3 is
    /// 15 in both directions of the captured exchange; its meaning is unknown.
    private func sendHello() async {
        guard let transport, isConnected else { return }
        let blob = RokidCapsCodec.encode([
            .uint32(0x1004),
            .uint32(sequence),
            .uint32(15),
            // The CXR service keys registration to this UUID: it is the official app's
            // client identity, recovered from the 2026-11-21 cold-connect capture. A
            // fresh UUID is ignored (Test A, 2026-11-21, fresh link and all); this one
            // is answered, and Dev_GetGlassInfo round-trips behind it — first proven
            // 2026-11-21 17:51 ET. How a new client UUID gets registered is still
            // unknown; until it is, this is the identity the probe presents.
            .string("7050c2b0-ce7a-43e4-9d12-ccf78672aa23"),
            .uint64(UInt64(Date().timeIntervalSince1970 * 1_000_000_000)),
            .uint32(transport.connectedProtocolID),
            .string(""),
        ])
        append("TX CXR hello (route 0x1004, protocol id \(transport.connectedProtocolID)) \(blob.count) B: \(hex(blob))")
        do {
            try await transport.send(blob)
            bytesOut += blob.count
            sequence &+= 1
            append("TX hello ok, next seq \(sequence)")
        } catch {
            append("TX hello failed: \(String(describing: error))")
        }
    }

    /// Mirror the official app's answer choreography inside a glasses-opened AI scene:
    /// heartbeat, the recognised question, ASR end, then the answer text. The scene is
    /// opened by the glasses themselves — a button press makes them send
    /// `Ai_SceneStatus` (aiAssistRunning true) and `KeyDown` — and the phone never
    /// starts it: the official app sends no `Ai_Start` anywhere in the 2026-11-21
    /// capture, and `TTS_Result` sent outside that scene is ignored, as this probe's
    /// standalone tries showed. Fire this within a few seconds of the button press.
    func sendAIAnswerDemo() async {
        // Paced to match the official app's captured timing (2026-11-21 cold-connect
        // capture, Q&A at 10:56:57-10:57:03): cloud status and a heartbeat as the
        // scene opens, ASR partials building the question over ~2 s, ASR_End, a
        // ~1.8 s "thinking" pause, then the answer. The first one-burst version of
        // this demo (all four sends in the same millisecond) rendered nothing —
        // the glasses' scene state machine appears to need the beats.
        await send(channel: "Sys", method: "Sys_Cloud_Server_Status", payload: .string("{\"status\":1}"), framing: framing)
        await send(channel: "Ai", method: "Ai_Heartbeat", payload: .string("{\"count\":1}"), framing: framing)
        try? await Task.sleep(nanoseconds: 450_000_000)
        await send(channel: "Ai", method: "ASR_Result", payload: .string("Who is"), framing: framing)
        try? await Task.sleep(nanoseconds: 450_000_000)
        await send(channel: "Ai", method: "ASR_Result", payload: .string("Who is Avenkin"), framing: framing)
        try? await Task.sleep(nanoseconds: 450_000_000)
        await send(channel: "Ai", method: "ASR_Result", payload: .string("Who is Avenkin?"), framing: framing)
        await send(channel: "Ai", method: "ASR_End", payload: nil, framing: framing)
        try? await Task.sleep(nanoseconds: 1_800_000_000)
        await send(channel: "Ai", method: "Ai_Heartbeat", payload: .string("{\"count\":1}"), framing: framing)
        await send(channel: "Ai", method: "TTS_Result", payload: .string(demoText), framing: framing)
    }

    func sendComposedCommand() async {
        let trimmedPayload = payloadText.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload: RokidCapsValue? = trimmedPayload.isEmpty ? nil : guessPayload(trimmedPayload)
        await send(channel: channel, method: method, payload: payload, framing: framing)
    }

    func sendRawHex() async {
        guard let transport, isConnected else {
            append("not connected — raw send skipped")
            return
        }
        guard let bytes = parseHex(rawHexText), !bytes.isEmpty else {
            append("raw hex: nothing usable to send")
            return
        }
        append("TX raw \(bytes.count) B: \(hex(bytes))")
        do {
            try await transport.send(bytes)
            bytesOut += bytes.count
            append("TX raw ok")
        } catch {
            append("TX raw failed: \(String(describing: error))")
        }
    }

    private func send(channel: String, method: String, payload: RokidCapsValue?, framing: RokidMFIFraming) async {
        guard let transport, isConnected else {
            append("not connected — send skipped")
            return
        }

        let frame = RokidIAP2Packet.encodeCommand(
            sequence: sequence,
            channel: channel,
            method: method,
            payload: payload,
            timestampMicroseconds: elapsedMicroseconds(),
            sessionID: sessionID
        )
        let wire = RokidMFIPayload.payload(for: frame, framing: framing)
        append("TX \(framing == .rawCaps ? "rawCaps" : "framed") \(frame.count) B frame, \(wire.count) B on the wire: \(hex(frame))")

        do {
            try await transport.send(wire)
            bytesOut += wire.count
            sequence &+= 1
            append("TX ok, next seq \(sequence)")
        } catch {
            append("TX failed: \(String(describing: error))")
        }
    }

    // MARK: - Inbound

    private func handleInbound(_ bytes: [UInt8]) {
        bytesIn += bytes.count
        append("RX \(bytes.count) B: \(hex(bytes))")

        if framing == .rawCaps {
            var offset = 0
            guard let caps = try? RokidCapsCodec.decode(bytes, offset: &offset), offset == bytes.count else {
                append("RX: not a decodable raw Caps blob")
                return
            }
            append("RX raw Caps tags \(caps.map { String($0.typeTag) }.joined())")
            if caps.count >= 5, case .uint32(0x1005) = caps[0] {
                var status = "-"
                if case .int32(let value) = caps[3] { status = String(value) }
                var address = "-"
                if case .string(let value) = caps[4] { address = value }
                append("RX CXR hello reply: status \(status), phone address \(address) — session registered")
            }
            if caps.count == 3, case .uint32(0x1003) = caps[0],
               case .string(let eventChannel) = caps[1],
               case .object(let eventObject) = caps[2],
               let firstMember = eventObject.first,
               case .string(let methodName) = firstMember {
                var detail = ""
                if eventObject.count > 1, case .string(let text) = eventObject[1] {
                    detail = " " + text
                }
                append("RX event \(eventChannel)/\(methodName)\(detail)")
            }
            if let message = RokidCapsMessage.decodeCaps(caps) {
                append("RX message method \(message.method) channel \(message.channel ?? "-") payload \(message.textPayload ?? "-")")
            }
            return
        }

        guard let frame = RokidIAP2Packet.decode(bytes) else {
            append("RX: not a decodable iAP2 frame (bad sync, length or checksum)")
            return
        }

        let seq = frame.sequence.map(String.init) ?? "none"
        append("RX frame route \(hex4(UInt16(truncatingIfNeeded: frame.route))) seq \(seq) ts \(frame.timestampMicroseconds) session \(hex4(frame.sessionID))")
        append("RX tags \(frame.caps.map { String($0.typeTag) }.joined())")

        if let message = RokidCapsMessage.decodeCaps(frame.caps) {
            append("RX message method \(message.method) channel \(message.channel ?? "-") payload \(message.textPayload ?? "-")")
        }
        if let transfer = RokidMediaTransfer.decode(bytes) {
            append("RX media chunk \(transfer.data.count) B")
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
        bytesIn = 0
        bytesOut = 0
    }

    var logText: String {
        entries.reversed().joined(separator: "\n")
    }

    // MARK: - Helpers

    private func elapsedMicroseconds() -> UInt32 {
        let elapsed = DispatchTime.now().uptimeNanoseconds &- clock.uptimeNanoseconds
        return UInt32(truncatingIfNeeded: elapsed / 1_000)
    }

    /// JSON object, bare integer, or plain text — whichever the typed payload most resembles.
    private func guessPayload(_ text: String) -> RokidCapsValue {
        if text.hasPrefix("{") || text.hasPrefix("[") { return .string(text) }
        if let value = Int32(text) { return .int32(value) }
        if let value = UInt32(text) { return .uint32(value) }
        return .string(text)
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func hex4(_ value: UInt16) -> String {
        String(format: "0x%04x", value)
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
/// transport and the codec, so it can be deleted again without touching anything else.
struct RokidDiagnosticsView: View {
    @StateObject private var model = RokidDiagnosticsModel()

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
            Toggle("Write raw Caps instead of a framed packet", isOn: $model.useRawCaps)
            HStack {
                Text("Session id")
                Spacer()
                TextField("1", text: $model.sessionIDText)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Text("Captures show 1 on one connection and 8 on another; the allocation rule is unknown. Try both.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack {
                Text("Sequence")
                Spacer()
                Text("\(model.sequence)")
                    .font(.system(.caption, design: .monospaced))
            }
            Button(model.isConnected ? "Disconnect" : "Open EASession") {
                Task { await model.toggleConnection() }
            }
            HStack {
                Text("Received").font(.caption)
                Spacer()
                Text("\(model.bytesIn) B in, \(model.bytesOut) B out")
                    .font(.system(.caption, design: .monospaced))
            }
        }
    }

    private var commandSection: some View {
        Section("Commands") {
            Button("Probe as rawCaps") {
                Task { await model.probe(.rawCaps) }
            }
            Button("Probe as framed (kills the session)") {
                Task { await model.probe(.framed) }
            }
            Text("Each probe sends Dev_GetGlassInfo, which is a read: the glasses answer with a device descriptor and change nothing.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("Use rawCaps. The accessory runs rokid::Caps::parse2 straight on the EA-session payload, and that parser requires 0x05 at byte 4. A framed packet puts 0x40 there, so the accessory rejects it and tears the session down, after which every write is ignored until you reconnect.")
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
            Text("Press the glasses' button first so the glasses open the AI scene — watch the log for Ai_SceneStatus and KeyDown — then tap this within a few seconds.")
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
            Button("Send raw bytes through the transport") {
                Task { await model.sendRawHex() }
            }
            Text("Goes through the same framing policy, so it is not a bypass.")
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

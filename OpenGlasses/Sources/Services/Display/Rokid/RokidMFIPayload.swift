/// How to hand a command to the transport.
///
/// **Settled on hardware, 2026-10-23.** `.rawCaps` is correct. The glasses' own
/// `cxr-service` receives an EA-session payload and calls `rokid::Caps::parse2` on it
/// directly (`NativeCXRService::handleEAPSessionPacket`, `libcxr_service_jni.so`),
/// which requires `[u32 BE total][0x05]` at byte 0 and bytes 4 == 5. A framed
/// `FF 5A` write instead puts `0x40` at byte 4, so `parse2` throws, the handler
/// returns -1, and the accessory tears the session down — which is exactly what the
/// device log showed (`removeEAPSessionId 0018`, then `handleEAPSessionPacket:002
/// return -1`, then every later 41-byte write arriving for a session that no longer
/// existed).
///
/// The `FF 5A` frame is what iOS's ExternalAccessory stack puts on the RFCOMM link —
/// that is why every capture, which is taken at HCI level, shows it. It is the MFi/iAP2
/// link layer's business, not ours.
enum RokidMFIFraming: Equatable {
    /// Write the whole iAP2 link frame: sync, length, header, Caps, checksum.
    /// Kept for the diagnostic probe and for any future accessory that expects it,
    /// but it is the wrong choice for this hardware.
    case framed
    /// Write only the Caps blob and let the MFi stack frame it. This is what works.
    case rawCaps
}

/// Framing policy for the MFi transport.
///
/// Deliberately separate from `RokidMFITransport`: this is pure byte arithmetic over
/// `RokidFrameDrain` and `RokidIAP2Packet`, with no `ExternalAccessory` dependency. Keeping it
/// Foundation-only means it compiles — and its tests run — anywhere, including the standalone
/// `swiftcheck` package, instead of only inside an iOS build.
enum RokidMFIPayload {
    /// What actually goes on the wire for one encoded command.
    static func payload(for bytes: [UInt8], framing: RokidMFIFraming) -> [UInt8] {
        switch framing {
        case .framed:
            return bytes
        case .rawCaps:
            // Leave anything we cannot prove is a frame completely alone.
            return rawCapsPayload(from: bytes) ?? bytes
        }
    }

    /// The Caps blob inside a complete link frame, or `nil` if `frame` is not one.
    static func rawCapsPayload(from frame: [UInt8]) -> [UInt8]? {
        guard RokidFrameDrain.isFrame(frame) else { return nil }
        let start = RokidIAP2Packet.prefixBytes + RokidIAP2Packet.headerBytesAfterLength
        let end = frame.count - 1
        guard end > start else { return nil }
        return Array(frame[start..<end])
    }
}

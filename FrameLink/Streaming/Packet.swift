import Foundation

/// FLNK | version (u8) | kind (u8) | sequence (u32 BE) | length (u32 BE) | payload.
struct Packet {
    enum Kind: UInt8 { case jpeg = 1, acknowledgement = 2, notice = 3 }
    static let headerSize = 14
    static let maximumPayload = 900_000
    let kind: Kind
    let sequence: UInt32
    let payload: Data

    func encoded() -> Data {
        precondition(payload.count <= Self.maximumPayload)
        var data = Data([0x46, 0x4C, 0x4E, 0x4B, 1, kind.rawValue])
        for value in [sequence, UInt32(payload.count)] {
            data.append(contentsOf: [UInt8(truncatingIfNeeded: value >> 24),
                                     UInt8(truncatingIfNeeded: value >> 16),
                                     UInt8(truncatingIfNeeded: value >> 8),
                                     UInt8(truncatingIfNeeded: value)])
        }
        data.append(payload)
        return data
    }

    init(kind: Kind, sequence: UInt32, payload: Data = Data()) {
        self.kind = kind
        self.sequence = sequence
        self.payload = payload
    }

    init?(data: Data) {
        guard data.count >= Self.headerSize,
              data.count <= Self.headerSize + Self.maximumPayload else { return nil }
        let bytes = [UInt8](data.prefix(Self.headerSize))
        guard Array(bytes[0..<5]) == [0x46, 0x4C, 0x4E, 0x4B, 1],
              let kind = Kind(rawValue: bytes[5]) else { return nil }
        func number(_ start: Int) -> UInt32 {
            bytes[start..<start + 4].reduce(0) { ($0 << 8) | UInt32($1) }
        }
        let length = Int(number(10))
        guard length == data.count - Self.headerSize,
              kind != .acknowledgement || length == 0,
              kind != .jpeg || length > 0,
              kind != .notice || length <= 512 else { return nil }
        self.kind = kind
        sequence = number(6)
        payload = Data(data.dropFirst(Self.headerSize))
    }
}

/// Accessed under VideoEncoder's lock. At most one frame may await display acknowledgement.
struct FrameGate {
    private(set) var pending: UInt32?
    private(set) var sentAt: TimeInterval = 0
    private(set) var roundTrip: TimeInterval = 1.0 / 24
    private var nextSequence: UInt32 = 0
    private var lastAttempt: TimeInterval = -.infinity

    mutating func reserve(now: TimeInterval) -> UInt32? {
        guard pending == nil, now - lastAttempt >= 1.0 / 24 else { return nil }
        nextSequence &+= 1
        pending = nextSequence
        sentAt = now
        lastAttempt = now
        return nextSequence
    }

    mutating func acknowledge(_ sequence: UInt32, now: TimeInterval) {
        guard pending == sequence else { return }
        roundTrip = roundTrip * 0.7 + max(0, now - sentAt) * 0.3
        pending = nil
    }

    func isStalled(now: TimeInterval) -> Bool { pending != nil && now - sentAt > 4 }
}

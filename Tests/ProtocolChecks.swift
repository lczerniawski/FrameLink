import Foundation

@main
struct ProtocolChecks {
    static func main() {
        let payload = Data([0xFF, 0xD8, 0x01, 0xFF, 0xD9])
        let frame = Packet(kind: .jpeg, sequence: 0x01020304, payload: payload).encoded()
        precondition(Array(frame.prefix(14)) == [0x46, 0x4C, 0x4E, 0x4B, 1, 1, 1, 2, 3, 4, 0, 0, 0, 5])
        let decoded = Packet(data: frame)!
        precondition(decoded.kind == .jpeg && decoded.sequence == 0x01020304 && decoded.payload == payload)
        for length in 0..<frame.count { precondition(Packet(data: Data(frame.prefix(length))) == nil) }
        var trailing = frame
        trailing.append(0)
        precondition(Packet(data: trailing) == nil)
        for index in [0, 4, 5, 10, 13] {
            var malformed = frame
            malformed[index] = 0xFF
            precondition(Packet(data: malformed) == nil)
        }
        precondition(Packet(data: Packet(kind: .jpeg, sequence: 1).encoded()) == nil)
        precondition(Packet(data: Packet(kind: .acknowledgement, sequence: 1, payload: payload).encoded()) == nil)
        let ack = Packet(data: Packet(kind: .acknowledgement, sequence: .max).encoded())!
        precondition(ack.sequence == .max && ack.payload.isEmpty)
        let notice = Packet(kind: .notice, sequence: 0, payload: Data("Camera paused".utf8))
        precondition(Packet(data: notice.encoded())?.kind == .notice)
        precondition(Packet(data: Packet(kind: .notice, sequence: 0, payload: Data(repeating: 0, count: 513)).encoded()) == nil)
        let maximum = Packet(kind: .jpeg, sequence: 42, payload: Data(repeating: 0xA5, count: Packet.maximumPayload))
        precondition(Packet(data: maximum.encoded())?.payload.count == Packet.maximumPayload)
        precondition(Packet(data: Data(repeating: 0, count: Packet.maximumPayload + Packet.headerSize + 1)) == nil)

        var gate = FrameGate()
        let first = gate.reserve(now: 0)!
        for time in stride(from: 0.01, through: 4.0, by: 0.01) {
            precondition(gate.reserve(now: time) == nil, "Never enqueue another frame while a frame is in flight")
        }
        gate.acknowledge(first &+ 1, now: 0.1)
        precondition(gate.pending == first, "Ignore stale or unrelated acknowledgements")
        precondition(!gate.isStalled(now: 4))
        precondition(gate.isStalled(now: 4.01))
        gate.acknowledge(first, now: 4.1)
        precondition(gate.pending == nil && !gate.isStalled(now: 10))
        let second = gate.reserve(now: 4.2)!
        precondition(second != first)
        gate.acknowledge(first, now: 4.21)
        precondition(gate.pending == second)
        gate.acknowledge(second, now: 4.22)
        precondition(gate.reserve(now: 4.23) == nil, "Limit encoding attempts to 24 FPS")
        precondition(gate.reserve(now: 4.25) != nil)
        gate = FrameGate()
        precondition(gate.reserve(now: 5) != nil, "Reconnect resets all backpressure state")
        print("Frame Link protocol and backpressure checks passed")
    }
}

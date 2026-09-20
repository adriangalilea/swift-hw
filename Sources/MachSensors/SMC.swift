import Foundation
import IOKit

// The AppleSMC user client, READ-ONLY BY CONSTRUCTION: this package holds
// no write function. Every message built here is a read (cmd 5) or a
// key-info query (cmd 9); `call` sends whatever message a caller composes
// on the public codec, which is how a privileged daemon composes its own
// cmd 6 without this package ever doing so. Public IOKit, no sudo, one
// connection for the object's life.
//
// Protocol: IOServiceMatching("AppleSMC") → IOServiceOpen →
// IOConnectCallStructMethod selector 2, one 80-byte SMCMessage in and one
// out. KERN_SUCCESS only says the call reached the kext; the reply's
// `result` byte says what the firmware did (0 ok, 0x84 no such key, 0x82
// rejected). Keys and data types are four-char codes composed big-endian
// into a UInt32. Payloads: `flt ` is a little-endian IEEE float, `ui8 `
// one byte, `ui16` two bytes big-endian. Read by KNOWN key, never by
// enumerating the key table (thousands of keys, milliseconds each).

/// The 80-byte wire struct, laid out as the kext reads it. Field order
/// and explicit padding ARE the codec: `SMC.init` asserts the size and
/// every offset a reader or writer depends on.
public struct SMCMessage {
    public enum Command: UInt8 {
        case readBytes = 5
        case writeBytes = 6
        case readKeyInfo = 9
    }

    public struct Version {
        public var major: UInt8 = 0
        public var minor: UInt8 = 0
        public var build: UInt8 = 0
        public var reserved: UInt8 = 0
        public var release: UInt16 = 0
    }

    public struct PowerLimit {
        public var version: UInt16 = 0
        public var length: UInt16 = 0
        public var cpu: UInt32 = 0
        public var gpu: UInt32 = 0
        public var memory: UInt32 = 0
    }

    public struct Info {
        public var dataSize: UInt32 = 0
        /// A four-char code, big-endian composed; `SMCMessage.dataType`
        /// spells it.
        public var dataType: UInt32 = 0
        public var dataAttributes: UInt8 = 0
        var padding: (UInt8, UInt8, UInt8) = (0, 0, 0)
    }

    public var key: UInt32 = 0
    public var vers = Version()
    public var pLimit = PowerLimit()
    public var keyInfo = Info()
    public var result: UInt8 = 0
    public var status: UInt8 = 0
    public var data8: UInt8 = 0
    var padding: UInt8 = 0
    public var data32: UInt32 = 0
    public var bytes:
        (
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
        ) = (
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        )

    public static let size = 80

    /// A zeroed message: the reply buffer.
    public init() {}

    /// A message for `key`: the command in `data8`, `dataSize` in the key
    /// info (a read wants the size the key-info query reported) and the
    /// payload, if any, in the leading bytes.
    public init(key: String, command: Command, dataSize: Int = 0, payload: [UInt8] = []) {
        precondition(payload.count <= SMCMessage.size - 48, "smc payload is at most 32 bytes")
        precondition(
            payload.isEmpty || payload.count == dataSize,
            "smc payload \(payload.count) bytes for a \(dataSize)-byte key")
        self.key = SMCMessage.code(key)
        data8 = command.rawValue
        keyInfo.dataSize = UInt32(dataSize)
        withUnsafeMutableBytes(of: &bytes) { buffer in
            for (i, byte) in payload.enumerated() { buffer[i] = byte }
        }
    }

    /// "FNum" → its UInt32, first character most significant.
    public static func code(_ name: String) -> UInt32 {
        precondition(name.utf8.count == 4, "smc key '\(name)' is not four characters")
        return name.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// The inverse of `code`.
    public static func name(_ code: UInt32) -> String {
        String(
            decoding: (0..<4).map { UInt8(truncatingIfNeeded: code >> (8 * (3 - $0))) },
            as: UTF8.self)
    }

    public var keyName: String { SMCMessage.name(key) }

    /// The reply's data type as the firmware spells it ("flt ", "ui8 ").
    public var dataType: String { SMCMessage.name(keyInfo.dataType) }

    /// The first `count` payload bytes.
    public func payload(_ count: Int) -> [UInt8] {
        precondition(count <= SMCMessage.size - 48, "smc payload is at most 32 bytes")
        return withUnsafeBytes(of: bytes) { Array($0.prefix(count)) }
    }
}

public enum SMCError: Error, CustomStringConvertible {
    /// No AppleSMC service is registered on this machine.
    case noService
    /// IOKit refused the call; the SMC never saw it.
    case ioKit(kern_return_t)
    /// The firmware answered 0x84: no such key.
    case noKey(String)
    /// The firmware answered a nonzero result other than 0x84 (0x82 is a
    /// write it would not take).
    case rejected(key: String, result: UInt8)
    /// The key exists with a type the reader does not decode.
    case unexpectedType(key: String, got: String, want: String)

    public var description: String {
        switch self {
        case .noService: return "smc: no AppleSMC service"
        case .ioKit(let rc): return "smc: iokit 0x\(String(UInt32(bitPattern: rc), radix: 16))"
        case .noKey(let key): return "smc: no key \(key)"
        case .rejected(let key, let result):
            return "smc: \(key) rejected, result 0x\(String(result, radix: 16))"
        case .unexpectedType(let key, let got, let want):
            return "smc: \(key) is '\(got)', wanted '\(want)'"
        }
    }
}

/// What the key-info query says about a key.
public struct KeyInfo: Sendable {
    public let type: String
    public let size: Int
}

/// One fan's live telemetry: rpm actual and target, and the mode byte (0
/// auto · 1 forced · 3 Apple's system mode) from the mode key as this
/// machine spells it. The envelope is `envelope(fan:)`, read apart: it is
/// a once-per-life value and `Mx` reads intermittently, so a 1 Hz sampler
/// never couples the two.
public struct FanReading: Sendable {
    public let index: Int
    public let actual: Double
    public let target: Double
    public let mode: UInt8
}

/// The envelope thermalmonitord publishes for one fan (`F{n}Mn`/`F{n}Mx`):
/// its thresholds, not the motor's limits. Read once and cached by every
/// consumer.
public struct FanEnvelope: Sendable {
    public let min: Double
    public let max: Double
}

public final class SMC {
    private let connection: io_connect_t
    /// "Md" or "md": the mode key's casing varies by silicon (`F0md` on
    /// M5), probed once per object with a key-info query.
    private var modeSuffix: String?

    public init() throws {
        precondition(MemoryLayout<SMCMessage>.size == SMCMessage.size, "SMCMessage is not 80 bytes")
        precondition(MemoryLayout<SMCMessage>.offset(of: \.keyInfo) == 28, "keyInfo is not at 28")
        precondition(MemoryLayout<SMCMessage>.offset(of: \.result) == 40, "result is not at 40")
        precondition(MemoryLayout<SMCMessage>.offset(of: \.data8) == 42, "data8 is not at 42")
        precondition(MemoryLayout<SMCMessage>.offset(of: \.data32) == 44, "data32 is not at 44")
        precondition(MemoryLayout<SMCMessage>.offset(of: \.bytes) == 48, "bytes are not at 48")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.noService }
        var opened: io_connect_t = 0
        let rc = IOServiceOpen(service, mach_task_self_, 0, &opened)
        IOObjectRelease(service)
        guard rc == KERN_SUCCESS else { throw SMCError.ioKit(rc) }
        connection = opened
    }

    deinit { IOServiceClose(connection) }

    /// One round trip for ANY message. IOKit failure is `ioKit`; a reply
    /// whose result byte is not 0 is `noKey` (0x84) or `rejected`. A
    /// returned message is one the firmware accepted.
    public func call(_ input: SMCMessage) throws -> SMCMessage {
        var output = SMCMessage()
        var outputSize = MemoryLayout<SMCMessage>.size
        let rc = withUnsafeBytes(of: input) { i in
            withUnsafeMutableBytes(of: &output) { o in
                IOConnectCallStructMethod(
                    connection, 2, i.baseAddress, i.count, o.baseAddress, &outputSize)
            }
        }
        guard rc == KERN_SUCCESS else { throw SMCError.ioKit(rc) }
        precondition(outputSize == SMCMessage.size, "smc replied \(outputSize) bytes")
        switch output.result {
        case 0: return output
        case 0x84: throw SMCError.noKey(input.keyName)
        default: throw SMCError.rejected(key: input.keyName, result: output.result)
        }
    }

    /// Type and size of a key (cmd 9): what a read sizes itself by and
    /// what a writer asserts before composing.
    public func info(_ key: String) throws -> KeyInfo {
        let reply = try call(SMCMessage(key: key, command: .readKeyInfo))
        return KeyInfo(type: reply.dataType, size: Int(reply.keyInfo.dataSize))
    }

    public func float(_ key: String) throws -> Float {
        let b = try read(key, as: "flt ")
        precondition(b.count == 4, "smc \(key) is a \(b.count)-byte flt")
        let bits = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
        return Float(bitPattern: bits)
    }

    public func uint8(_ key: String) throws -> UInt8 {
        let b = try read(key, as: "ui8 ")
        precondition(b.count == 1, "smc \(key) is a \(b.count)-byte ui8")
        return b[0]
    }

    public func uint16(_ key: String) throws -> UInt16 {
        let b = try read(key, as: "ui16")
        precondition(b.count == 2, "smc \(key) is a \(b.count)-byte ui16")
        return UInt16(b[0]) << 8 | UInt16(b[1])
    }

    /// The mode key of fan `n` as this machine spells it: `F{n}Md`, or
    /// `F{n}md` where the upper-case key does not exist. Probed on the
    /// first call, cached for the object's life.
    public func modeKey(fan n: Int) throws -> String {
        if modeSuffix == nil {
            do {
                _ = try info("F0Md")
                modeSuffix = "Md"
            } catch SMCError.noKey {
                _ = try info("F0md")
                modeSuffix = "md"
            }
        }
        return "F\(n)\(modeSuffix!)"
    }

    /// Every fan `FNum` counts, in index order, live telemetry only; empty
    /// on a fanless Mac.
    public func fans() throws -> [FanReading] {
        let count = Int(try uint8("FNum"))
        return try (0..<count).map { n in
            FanReading(
                index: n,
                actual: Double(try float("F\(n)Ac")),
                target: Double(try float("F\(n)Tg")),
                mode: try uint8(modeKey(fan: n)))
        }
    }

    /// Fan `n`'s reported envelope. Read ONCE per consumer life, never at
    /// the sample rate: `F{n}Mx` reads intermittently on Apple Silicon.
    public func envelope(fan n: Int) throws -> FanEnvelope {
        FanEnvelope(min: Double(try float("F\(n)Mn")), max: Double(try float("F\(n)Mx")))
    }

    /// The bytes of `key`, sized by its key info, after asserting its type.
    private func read(_ key: String, as want: String) throws -> [UInt8] {
        let info = try info(key)
        guard info.type == want else {
            throw SMCError.unexpectedType(key: key, got: info.type, want: want)
        }
        let reply = try call(SMCMessage(key: key, command: .readBytes, dataSize: info.size))
        return reply.payload(info.size)
    }
}

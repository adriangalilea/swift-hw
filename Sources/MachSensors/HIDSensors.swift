import Foundation
import IOKit

/// One thermal sensor as the HID event system names it, with a valid
/// reading (10 to 120 °C; anything else is a sensor that did not answer).
public struct Sensor: Sendable {
    /// Which die block a sensor's name places it in. The die sensors are
    /// `cpu` and `gpu`: `hottest` ranges over them and nothing else.
    public enum Block: String, Sendable {
        case cpu
        case gpu
        case other
    }

    public let name: String
    public let celsius: Double
    public let block: Block
}

public enum HIDSensorsError: Error, CustomStringConvertible {
    /// IOKit no longer exports the HID event system SPI by that name.
    case symbolMissing(String)
    case clientFailed

    public var description: String {
        switch self {
        case .symbolMissing(let s): return "hid: IOKit has no \(s)"
        case .clientFailed: return "hid: IOHIDEventSystemClientCreate returned nil"
        }
    }
}

// Die temperatures from the HID event system, the one source that is
// right on Apple Silicon: every thermal sensor is a HID service (usage
// page 0xff00, usage 5) with a NAME. M1/M2 name theirs by block ("pACC
// MTR Temp Sensor", "eACC…", "GPU MTR Temp Sensor"); M3 onward publish
// the die as "PMU tdie<n>" with no block named, so the die is the cpu
// block and the gpu has no sensor of its own. IOKit SPI, loaded by name.
public final class HIDSensors {
    private typealias ClientCreate = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias SetMatching = @convention(c) (CFTypeRef, CFDictionary) -> Void
    private typealias CopyServices = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias CopyProperty = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEvent =
        @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias FloatValue = @convention(c) (CFTypeRef, Int32) -> Double

    private static let temperatureType: Int64 = 15
    private static let temperatureField: Int32 = 15 << 16

    private let copyEvent: CopyEvent
    private let floatValue: FloatValue
    /// Held for the object's life: services answer only while their
    /// client exists.
    private let client: CFTypeRef
    private let services: [(service: CFTypeRef, name: String, block: Sensor.Block)]

    public init() throws {
        let lib = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
        func symbol(_ name: String) throws -> UnsafeMutableRawPointer {
            guard let p = dlsym(lib, name) else { throw HIDSensorsError.symbolMissing(name) }
            return p
        }
        let create = unsafeBitCast(
            try symbol("IOHIDEventSystemClientCreate"), to: ClientCreate.self)
        let match = unsafeBitCast(
            try symbol("IOHIDEventSystemClientSetMatching"), to: SetMatching.self)
        let copyServices = unsafeBitCast(
            try symbol("IOHIDEventSystemClientCopyServices"), to: CopyServices.self)
        let copyProperty = unsafeBitCast(
            try symbol("IOHIDServiceClientCopyProperty"), to: CopyProperty.self)
        copyEvent = unsafeBitCast(try symbol("IOHIDServiceClientCopyEvent"), to: CopyEvent.self)
        floatValue = unsafeBitCast(try symbol("IOHIDEventGetFloatValue"), to: FloatValue.self)
        guard let client = create(kCFAllocatorDefault)?.takeRetainedValue() else {
            throw HIDSensorsError.clientFailed
        }
        match(client, ["PrimaryUsagePage": 0xFF00, "PrimaryUsage": 5] as CFDictionary)
        let found = copyServices(client)?.takeRetainedValue() as? [CFTypeRef] ?? []
        let named = found.map { service in
            (
                service,
                copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String ?? "?"
            )
        }
        let blockNamed = named.contains { $0.1.contains("ACC MTR Temp Sensor") }
        self.client = client
        services = named.map { service, name in
            let block: Sensor.Block =
                name.contains("ACC MTR Temp Sensor")
                ? .cpu
                : name.contains("GPU MTR Temp Sensor")
                    ? .gpu : !blockNamed && name.hasPrefix("PMU tdie") ? .cpu : .other
            return (service, name, block)
        }
    }

    /// Every sensor that answers with a valid temperature, in service order.
    public func readings() -> [Sensor] {
        services.compactMap { service, name, block in
            guard
                let event = copyEvent(service, HIDSensors.temperatureType, 0, 0)?
                    .takeRetainedValue()
            else { return nil }
            let celsius = floatValue(event, HIDSensors.temperatureField)
            guard celsius > 10 && celsius < 120 else { return nil }
            return Sensor(name: name, celsius: celsius, block: block)
        }
    }

    /// The hottest die sensor: what a fan curve is driven by. Never a
    /// mean; a 14-die chip spreads several degrees under load.
    public func hottest() -> Sensor? {
        readings().filter { $0.block != .other }.max { $0.celsius < $1.celsius }
    }
}

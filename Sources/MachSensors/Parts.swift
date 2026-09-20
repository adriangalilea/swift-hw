import Foundation

/// The chip's parts with a NAME, read from the SMC. From M3 on the HID
/// path names the SoC's sensors `PMU tdie<n>`, the power management
/// unit's dies (they warm when charging, and read under the cores), and
/// says nothing about cpu or gpu; the SMC carries per-generation keys
/// that do. The keys are exelban/stats' catalogue (MIT,
/// github.com/exelban/stats, Modules/Sensors/values.swift at
/// 0edcad84e0e9), vendored for M3, M4 and M5. Probed once with
/// READ_KEYINFO: a key the catalogue lists and this Mac lacks is dropped.
public final class Parts {
    public enum Group: String, CaseIterable, Sendable {
        case cpu, gpu, memory
    }

    public struct Reading: Sendable {
        public let group: Group
        public let celsius: [Double]
    }

    /// The single number a fan curve follows: the hottest cpu or gpu
    /// sensor, and how many sensors it was the max of.
    public struct Hottest: Sendable {
        public let group: Group
        public let celsius: Double
        public let sensors: Int
    }

    private let smc: SMC
    /// The keys this Mac answers, by group.
    public let present: [Group: [String]]
    /// The catalogue's count per group, for the probe's report.
    public let catalogued: [Group: Int]
    public let generation: Int?

    public init(smc: SMC) {
        self.smc = smc
        generation = Parts.generation
        let keys = generation.map(Parts.keys(generation:)) ?? [:]
        catalogued = keys.mapValues(\.count)
        var found: [Group: [String]] = [:]
        for (group, list) in keys {
            let live = list.filter { key in
                guard let info = try? smc.info(key) else { return false }
                return info.type == "flt " && info.size == 4
            }
            if !live.isEmpty { found[group] = live }
        }
        present = found
    }

    /// The chip generation from the brand string, `Apple M5 Max` → 5.
    public static var generation: Int? {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0)
        let brand = String(cString: bytes)
        guard let m = brand.range(of: #"Apple M(\d+)"#, options: .regularExpression) else {
            return nil
        }
        return Int(brand[m].dropFirst(7))
    }

    /// The catalogue: generation → group → keys.
    public static func keys(generation: Int) -> [Group: [String]] {
        switch generation {
        case 3:
            return [
                .cpu: [
                    "Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E",
                    "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E",
                ],
                .gpu: ["Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"],
            ]
        case 4:
            return [
                .cpu: [
                    "Te05", "Te0S", "Te09", "Te0H", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y",
                    "Tp0b", "Tp0e",
                ],
                .gpu: ["Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k"],
                .memory: ["Tm0p", "Tm1p", "Tm2p"],
            ]
        case 5:
            return [
                .cpu: [
                    "Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K", "Tp0O", "Tp0R", "Tp0U", "Tp0X",
                    "Tp0a", "Tp0d", "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y",
                ],
                .gpu: ["Tg0U", "Tg0X", "Tg0d", "Tg0g", "Tg0j", "Tg1Y", "Tg1c", "Tg1g"],
            ]
        default:
            return [:]
        }
    }

    /// One reading per present group, every key's value, invalid ones
    /// dropped, in `Group` order.
    public func readings() -> [Reading] {
        Group.allCases.compactMap { group in
            guard let keys = present[group] else { return nil }
            let values = keys.compactMap { key -> Double? in
                guard let v = try? smc.float(key), v > 10, v < 130 else { return nil }
                return Double(v)
            }
            return values.isEmpty ? nil : Reading(group: group, celsius: values)
        }
    }

    /// The hottest cpu or gpu sensor; nil when neither group is present
    /// (an M1/M2, or a generation the catalogue does not know).
    public func hottest() -> Hottest? {
        let dies = readings().filter { $0.group != .memory }
        guard
            let top = dies.flatMap({ r in r.celsius.map { (r.group, $0) } })
                .max(by: { $0.1 < $1.1 })
        else { return nil }
        return Hottest(
            group: top.0, celsius: top.1, sensors: dies.reduce(0) { $0 + $1.celsius.count })
    }
}

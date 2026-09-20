# swift-hw

The Mac's hardware senses as one Swift package, read-only by construction. macOS 13 and up, Apple Silicon.

```swift
.package(url: "https://github.com/adriangalilea/swift-hw", from: "0.1.0")
// product: MachSensors
```

`MachSensors` has three readers:

- `HIDSensors`: every thermal sensor the HID event system names, with a valid reading; `readings()` and the hottest die. M1/M2 name their sensors by block, M3 onward publish the die as `PMU tdie<n>`.
- `SMC`: the AppleSMC user client over public IOKit, no sudo. `info` (key type and size), typed reads (`flt `, `ui8`, `ui16`), `fans()` from `FNum`, typed errors from the result byte, and the public 80-byte `SMCMessage` codec. The package holds no write function: a privileged daemon composes its own write on the codec and sends it through `call`.
- `Parts`: the SMC temperature keys that name the chip's parts (cpu, gpu, memory) per generation, probed once with READ_KEYINFO; `readings()` and `hottest()`. The catalogue is exelban/stats' (MIT, github.com/exelban/stats, `Modules/Sensors/values.swift`), the one maintained list of Apple's unpublished keys.

Consumers: [mach](https://github.com/adriangalilea/mach) (is this Mac truly yours, and how fast) and [chill](https://github.com/adriangalilea/chill) (fan control with Apple in charge by default).

```
mise run check   # format + build, 0 warnings
```

MIT, see LICENSE.

import Darwin
import Foundation
import IOKit

enum ThermalSensorGroup: String {
    case die
    case cpu
    case gpu
    case soc
}

struct ThermalReading {
    let group: ThermalSensorGroup
    let valueCelsius: Double
}

struct FanReading {
    let currentRPM: Double
    let maximumRPM: Double?
}

struct ThermalSnapshot {
    let readings: [ThermalReading]
    let fans: [FanReading]?
    let macOSState: String

    func values(for group: ThermalSensorGroup) -> [Double] {
        readings.filter { $0.group == group }.map(\.valueCelsius)
    }

    func maximum(for group: ThermalSensorGroup) -> Double? {
        values(for: group).max()
    }

    func average(for group: ThermalSensorGroup) -> Double? {
        let values = values(for: group)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    var line: String {
        let allValues = readings.map(\.valueCelsius)
        var parts = [
            "sensor_avg=\(formatTemperature(averageTemperature(allValues)))",
            "sensor_max=\(formatTemperature(allValues.max()))"
        ]
        for group in [ThermalSensorGroup.cpu, .gpu, .soc] {
            parts.append("\(group.rawValue)_sensor_avg=\(formatTemperature(average(for: group)))")
            parts.append("\(group.rawValue)_sensor_max=\(formatTemperature(maximum(for: group)))")
        }

        if let fans {
            if fans.isEmpty {
                parts.append("fans=none")
            } else {
                let values = fans.map { fan in
                    var value = "\(Int(fan.currentRPM.rounded()))rpm"
                    if let maximum = fan.maximumRPM, maximum > 0 {
                        value += "/max=\(Int(maximum.rounded()))rpm"
                    }
                    return value
                }
                parts.append("fans=\(fans.count):\(values.joined(separator: ","))")
            }
        } else {
            parts.append("fans=unavailable")
        }
        parts.append("macos_state=\(macOSState)")
        return parts.joined(separator: " ")
    }
}

private func averageTemperature(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    return values.reduce(0, +) / Double(values.count)
}

private func formatTemperature(_ value: Double?) -> String {
    guard let value else { return "unavailable" }
    return String(format: "%.1fC", value)
}

func macOSThermalState() -> String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    @unknown default: return "unknown"
    }
}

func collectThermalSnapshot() -> ThermalSnapshot {
    let smc = readSMCSnapshot()
    return ThermalSnapshot(
        readings: smc.readings.isEmpty ? readHIDTemperatureSensors() : smc.readings,
        fans: smc.fans,
        macOSState: macOSThermalState()
    )
}

func thermalGroup(for name: String) -> ThermalSensorGroup? {
    let name = name.lowercased()
    if name.hasPrefix("gpu mtr temp") || name.contains("gpu") {
        return .gpu
    }
    if name.hasPrefix("pacc mtr temp") || name.hasPrefix("eacc mtr temp")
        || name.contains("cpu") {
        return .cpu
    }
    if name.hasPrefix("soc mtr temp") || name.hasPrefix("pmgr soc die")
        || name.contains("soc") {
        return .soc
    }
    if name.hasPrefix("pmu tdie") || name.hasPrefix("pmu tdev")
        || name.hasPrefix("pmu2 tdie") || name.hasPrefix("pmu2 tdev") {
        return .die
    }
    return nil
}

private func loadSymbol<T>(_ handle: UnsafeMutableRawPointer, _ name: String, as type: T.Type) -> T? {
    guard let symbol = dlsym(handle, name) else { return nil }
    return unsafeBitCast(symbol, to: type)
}

private func releaseCFPointer(_ pointer: UnsafeMutableRawPointer) {
    Unmanaged<CFTypeRef>.fromOpaque(pointer).release()
}

private func readHIDTemperatureSensors() -> [ThermalReading] {
    typealias Create = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
    typealias SetMatching = @convention(c) (UnsafeMutableRawPointer, CFDictionary) -> Int32
    typealias CopyServices = @convention(c) (UnsafeMutableRawPointer) -> Unmanaged<CFArray>?
    typealias CopyProperty = @convention(c) (UnsafeMutableRawPointer, CFString) -> Unmanaged<AnyObject>?
    typealias CopyEvent = @convention(c) (UnsafeMutableRawPointer, Int64, Int32, Int64) -> UnsafeMutableRawPointer?
    typealias GetFloatValue = @convention(c) (UnsafeMutableRawPointer, Int32) -> Double

    guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else {
        return []
    }
    defer { dlclose(handle) }

    guard let create = loadSymbol(handle, "IOHIDEventSystemClientCreate", as: Create.self),
          let setMatching = loadSymbol(handle, "IOHIDEventSystemClientSetMatching", as: SetMatching.self),
          let copyServices = loadSymbol(handle, "IOHIDEventSystemClientCopyServices", as: CopyServices.self),
          let copyProperty = loadSymbol(handle, "IOHIDServiceClientCopyProperty", as: CopyProperty.self),
          let copyEvent = loadSymbol(handle, "IOHIDServiceClientCopyEvent", as: CopyEvent.self),
          let getFloatValue = loadSymbol(handle, "IOHIDEventGetFloatValue", as: GetFloatValue.self),
          let system = create(kCFAllocatorDefault) else {
        return []
    }
    defer { releaseCFPointer(system) }

    var usagePage: Int32 = 0xff00
    var usage: Int32 = 5
    guard let pageNumber = CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &usagePage),
          let usageNumber = CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &usage) else {
        return []
    }
    let matching = [
        "PrimaryUsagePage" as CFString: pageNumber,
        "PrimaryUsage" as CFString: usageNumber
    ] as CFDictionary
    _ = setMatching(system, matching)

    guard let services = copyServices(system)?.takeRetainedValue() else { return [] }
    let temperatureEventType: Int64 = 15
    let temperatureField = Int32(temperatureEventType << 16)
    var readings: [ThermalReading] = []

    let serviceCount = min(CFArrayGetCount(services), 256)
    for index in 0..<serviceCount {
        guard let rawService = CFArrayGetValueAtIndex(services, index) else { continue }
        let service = UnsafeMutableRawPointer(mutating: rawService)
        guard let property = copyProperty(service, "Product" as CFString),
              let name = property.takeRetainedValue() as? String,
              let group = thermalGroup(for: name),
              let event = copyEvent(service, temperatureEventType, 0, 0) else {
            continue
        }
        let value = getFloatValue(event, temperatureField)
        releaseCFPointer(event)
        guard value.isFinite, value >= 5, value <= 110 else { continue }
        readings.append(ThermalReading(group: group, valueCelsius: value))
    }
    return readings
}

private let smcDataSize = 80
private let smcSelector: UInt32 = 2
private let smcReadBytes: UInt8 = 5
private let smcReadKeyInfo: UInt8 = 9

func packSMCKey(_ key: String) -> UInt32 {
    var result: UInt32 = 0
    for (index, byte) in key.utf8.prefix(4).enumerated() {
        result |= UInt32(byte) << ((3 - index) * 8)
    }
    return result
}

func unpackSMCType(_ value: UInt32) -> String {
    let bytes: [UInt8] = [
        UInt8((value >> 24) & 0xff),
        UInt8((value >> 16) & 0xff),
        UInt8((value >> 8) & 0xff),
        UInt8(value & 0xff)
    ]
    return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
}

private func openSMC() -> io_connect_t? {
    guard let matching = IOServiceMatching("AppleSMC") else { return nil }
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
        return nil
    }
    defer { IOObjectRelease(iterator) }
    let service = IOIteratorNext(iterator)
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }

    var connection: io_connect_t = 0
    guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
    return connection
}

private func readSMCKey(_ connection: io_connect_t, _ key: String) -> (type: String, bytes: [UInt8])? {
    let packedKey = packSMCKey(key)
    var input = [UInt8](repeating: 0, count: smcDataSize)
    var output = [UInt8](repeating: 0, count: smcDataSize)
    input.withUnsafeMutableBytes { buffer in
        buffer.storeBytes(of: packedKey, toByteOffset: 0, as: UInt32.self)
        buffer.storeBytes(of: smcReadKeyInfo, toByteOffset: 42, as: UInt8.self)
    }

    var outputSize = smcDataSize
    let keyInfoResult = input.withUnsafeBytes { inputBuffer in
        output.withUnsafeMutableBytes { outputBuffer in
            IOConnectCallStructMethod(
                connection,
                smcSelector,
                inputBuffer.baseAddress,
                inputBuffer.count,
                outputBuffer.baseAddress,
                &outputSize
            )
        }
    }
    guard keyInfoResult == KERN_SUCCESS, outputSize >= 41, output[40] == 0 else { return nil }

    let dataSize = output.withUnsafeBytes {
        $0.loadUnaligned(fromByteOffset: 28, as: UInt32.self)
    }
    let dataType = output.withUnsafeBytes {
        $0.loadUnaligned(fromByteOffset: 32, as: UInt32.self)
    }
    let readSize = min(Int(dataSize), 32)
    guard readSize > 0 else { return nil }

    input = [UInt8](repeating: 0, count: smcDataSize)
    output = [UInt8](repeating: 0, count: smcDataSize)
    input.withUnsafeMutableBytes { buffer in
        buffer.storeBytes(of: packedKey, toByteOffset: 0, as: UInt32.self)
        buffer.storeBytes(of: UInt32(readSize), toByteOffset: 28, as: UInt32.self)
        buffer.storeBytes(of: smcReadBytes, toByteOffset: 42, as: UInt8.self)
    }
    outputSize = smcDataSize
    let readResult = input.withUnsafeBytes { inputBuffer in
        output.withUnsafeMutableBytes { outputBuffer in
            IOConnectCallStructMethod(
                connection,
                smcSelector,
                inputBuffer.baseAddress,
                inputBuffer.count,
                outputBuffer.baseAddress,
                &outputSize
            )
        }
    }
    guard readResult == KERN_SUCCESS, outputSize >= 48 + readSize, output[40] == 0 else { return nil }
    return (unpackSMCType(dataType), Array(output[48..<(48 + readSize)]))
}

private func readSMCUInt8(_ connection: io_connect_t, _ key: String) -> UInt8? {
    guard let value = readSMCKey(connection, key), value.type == "ui8", let byte = value.bytes.first else {
        return nil
    }
    return byte
}

private func readSMCRPM(_ connection: io_connect_t, _ key: String) -> Double? {
    guard let value = readSMCKey(connection, key) else { return nil }
    return decodeSMCRPM(type: value.type, bytes: value.bytes)
}

func decodeSMCRPM(type: String, bytes: [UInt8]) -> Double? {
    if type == "fpe2", bytes.count >= 2 {
        let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
        let rpm = Double(raw) / 4
        return rpm <= 20_000 ? rpm : nil
    }
    if type == "flt", bytes.count >= 4 {
        let raw = UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
        let rpm = Double(Float(bitPattern: raw))
        return rpm.isFinite && rpm >= 0 && rpm <= 20_000 ? rpm : nil
    }
    return nil
}

private func readSMCTemperature(_ connection: io_connect_t, _ key: String) -> Double? {
    guard let value = readSMCKey(connection, key) else { return nil }
    return decodeSMCTemperature(type: value.type, bytes: value.bytes)
}

func decodeSMCTemperature(type: String, bytes: [UInt8]) -> Double? {
    let temperature: Double?
    if type == "flt", bytes.count >= 4 {
        let raw = UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
        temperature = Double(Float(bitPattern: raw))
    } else if type == "sp78", bytes.count >= 2 {
        let raw = Int16(bitPattern: (UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
        temperature = Double(raw) / 256
    } else {
        temperature = nil
    }
    guard let temperature, temperature.isFinite, temperature >= 5, temperature <= 110 else {
        return nil
    }
    return temperature
}

private func firstSMCTemperature(_ connection: io_connect_t, keys: [String]) -> Double? {
    for key in keys {
        if let temperature = readSMCTemperature(connection, key) {
            return temperature
        }
    }
    return nil
}

private func readSMCSnapshot() -> (readings: [ThermalReading], fans: [FanReading]?) {
    guard let connection = openSMC() else { return ([], nil) }
    defer { IOServiceClose(connection) }

    let thermalKeys: [([String], ThermalSensorGroup)] = [
        (["TCMz", "TCMb", "TCDX"], .cpu),
        (["TRDX"], .gpu),
        (["TPMP"], .soc)
    ]
    let readings = thermalKeys.compactMap { keys, group in
        firstSMCTemperature(connection, keys: keys).map {
            ThermalReading(group: group, valueCelsius: $0)
        }
    }

    let fans: [FanReading]?
    if let fanCount = readSMCUInt8(connection, "FNum") {
        let expectedCount = min(Int(fanCount), 8)
        let readings = (0..<expectedCount).compactMap { index -> FanReading? in
            guard let current = readSMCRPM(connection, "F\(index)Ac") else { return nil }
            return FanReading(
                currentRPM: current,
                maximumRPM: readSMCRPM(connection, "F\(index)Mx")
            )
        }
        fans = expectedCount > 0 && readings.isEmpty ? nil : readings
    } else {
        fans = nil
    }
    return (readings, fans)
}

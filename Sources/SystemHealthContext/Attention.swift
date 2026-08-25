import Foundation

enum MemoryPressureLevel: String {
    case normal
    case warning
    case critical
    case unknown
}

struct StorageStatus {
    let usedPercent: Double?
    let freeBytes: UInt64?

    var line: String {
        guard let usedPercent, let freeBytes else { return "disk=unknown free=unknown" }
        return "disk=\(Int(usedPercent.rounded()))% free=\(formatGB(freeBytes))"
    }
}

struct MemoryStatus {
    let pressure: MemoryPressureLevel
    let detail: String

    var line: String {
        "pressure=\(pressure.rawValue) \(detail)"
    }
}

struct SecurityStatus {
    let syspolicydCPU: Double
    let trustdCPU: Double
    let sandboxdCPU: Double

    var line: String {
        "syspolicyd=\(formatPercent(syspolicydCPU)) trustd=\(formatPercent(trustdCPU)) sandboxd=\(formatPercent(sandboxdCPU))"
    }
}

struct AttentionReason: Equatable {
    let code: String
    let summary: String
    let severity: Int
}

struct AttentionAssessment {
    let reasons: [AttentionReason]

    var required: Bool { !reasons.isEmpty }

    var line: String {
        guard required else { return "none" }
        return "required " + reasons.map(\.summary).joined(separator: " | ")
    }
}

private let gigabyte: UInt64 = 1_000_000_000

func assessAttention(
    storage: StorageStatus,
    memory: MemoryStatus,
    security: SecurityStatus,
    thermals: ThermalSnapshot,
    processes: [ProcessSample],
    now: TimeInterval = Date().timeIntervalSince1970
) -> AttentionAssessment {
    var reasons: [AttentionReason] = []

    if let usedPercent = storage.usedPercent, usedPercent >= 90 {
        reasons.append(AttentionReason(
            code: "storage_pressure",
            summary: "internal disk is \(Int(usedPercent.rounded()))% used",
            severity: usedPercent >= 97 ? 100 : 80
        ))
    } else if let freeBytes = storage.freeBytes, freeBytes < 20 * gigabyte {
        reasons.append(AttentionReason(
            code: "storage_pressure",
            summary: "internal disk has \(formatGB(freeBytes)) free",
            severity: 85
        ))
    }

    if memory.pressure == .warning || memory.pressure == .critical {
        reasons.append(AttentionReason(
            code: "memory_pressure",
            summary: "memory pressure is \(memory.pressure.rawValue)",
            severity: memory.pressure == .critical ? 100 : 85
        ))
    }

    var thermalFacts: [String] = []
    var thermalSeverity = 0
    let maximumTemperature = thermals.readings.map(\.valueCelsius).max()
    if let temperature = maximumTemperature, temperature >= 90 {
        thermalFacts.append("sensor=\(formatTemperatureForReason(temperature))")
        thermalSeverity = max(thermalSeverity, temperature >= 100 ? 100 : 90)
    }
    if thermals.macOSState == "serious" || thermals.macOSState == "critical" {
        thermalFacts.append("macos_state=\(thermals.macOSState)")
        thermalSeverity = max(thermalSeverity, thermals.macOSState == "critical" ? 100 : 95)
    }
    let fanRatios = thermals.fans?.compactMap { fan -> Double? in
        guard let maximum = fan.maximumRPM, maximum > 0 else { return nil }
        return fan.currentRPM / maximum
    }
    let hottestFanRatio = fanRatios?.max()
    let hottestFanRPM = thermals.fans?.map(\.currentRPM).max()
    if let hottestFanRatio, hottestFanRatio >= 0.85 {
        thermalFacts.append("fan=\(Int((hottestFanRatio * 100).rounded()))%_of_max")
        thermalSeverity = max(thermalSeverity, 88)
    } else if let hottestFanRPM, hottestFanRPM >= 5_000 {
        thermalFacts.append("fan=\(Int(hottestFanRPM.rounded()))rpm")
        thermalSeverity = max(thermalSeverity, 86)
    }
    if thermalSeverity > 0 {
        reasons.append(AttentionReason(
            code: "thermal_pressure",
            summary: "thermal pressure \(thermalFacts.joined(separator: " "))",
            severity: thermalSeverity
        ))
    }

    let securityCPU = security.syspolicydCPU + security.trustdCPU + security.sandboxdCPU
    if securityCPU >= 50 {
        reasons.append(AttentionReason(
            code: "security_daemon_cpu",
            summary: "macOS security daemons are using \(formatPercent(securityCPU)) CPU",
            severity: securityCPU >= 100 ? 98 : 88
        ))
    }

    if let processReason = highestProcessConcern(processes, now: now) {
        reasons.append(processReason)
    }

    let selected = reasons
        .sorted {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            return $0.code < $1.code
        }
        .prefix(3)
    return AttentionAssessment(reasons: Array(selected))
}

private func formatTemperatureForReason(_ value: Double) -> String {
    String(format: "%.1fC", value)
}

private func highestProcessConcern(_ processes: [ProcessSample], now: TimeInterval) -> AttentionReason? {
    processes.compactMap { processConcern($0, now: now) }.max {
        if $0.severity != $1.severity { return $0.severity < $1.severity }
        return $0.summary > $1.summary
    }
}

private func processConcern(_ process: ProcessSample, now: TimeInterval) -> AttentionReason? {
    let kind = helperKind(process)
    let helper = kind != nil && kind != "app_server"
    let host = isCodexHostProcess(process)
    guard helper || host else { return nil }

    let age = max(0, now - process.startTime)
    let averageCPU = lifetimeAverageCPU(process, now: now)
    let writeRate = lifetimeAverageRate(bytes: process.diskWriteBytes, process: process, now: now)
    let wakeupRate = lifetimeWakeupRate(process, now: now)
    let memoryThreshold = helper ? 4 * gigabyte : 8 * gigabyte
    let parentIsPID1 = helper && process.ppid == 1

    var severity = 0
    if helper, age >= 10 * 60, process.cpuPercent >= 100 {
        severity = max(severity, process.cpuPercent >= 200 ? 100 : 92)
    }
    if age >= 30 * 60, averageCPU >= 50 {
        severity = max(severity, averageCPU >= 100 ? 98 : 90)
    }
    if age >= 30 * 60, process.memoryBytes >= memoryThreshold {
        severity = max(severity, process.memoryBytes >= 8 * gigabyte ? 98 : 90)
    }
    if age >= 10 * 60, writeRate >= 20_000_000 {
        severity = max(severity, writeRate >= 100_000_000 ? 100 : 92)
    }
    if age >= 10 * 60, wakeupRate >= 1_000 {
        severity = max(severity, 88)
    }
    guard severity > 0 else { return nil }

    var facts = [
        "age=\(formatAge(age))",
        "cpu_now=\(formatPercent(process.cpuPercent))",
        "cpu_avg=\(formatPercent(averageCPU))",
        "memory=\(formatBytes(process.memoryBytes))"
    ]
    if parentIsPID1 { facts.append("parent_pid_1=yes") }
    if writeRate >= 20_000_000 { facts.append("write_avg=\(formatRate(writeRate))") }
    if wakeupRate >= 1_000 { facts.append("wakeups_avg=\(formatCountRate(wakeupRate))") }

    return AttentionReason(
        code: "codex_process_pressure",
        summary: "\(processLabel(process)) \(facts.joined(separator: " "))",
        severity: severity
    )
}

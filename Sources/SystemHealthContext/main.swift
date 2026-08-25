import CoreWLAN
import Darwin
import Foundation
import IOKit.ps
import SystemConfiguration

func currentHookVersion() -> String { "0.5.0" }

let machTimebase: mach_timebase_info_data_t = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return info
}()

func nanosecondsFromMachTicks(
    _ ticks: UInt64,
    numerator: UInt32 = machTimebase.numer,
    denominator: UInt32 = machTimebase.denom
) -> UInt64 {
    guard denominator > 0 else { return ticks }
    let divisor = UInt64(denominator)
    let multiplier = UInt64(numerator)
    let whole = ticks / divisor
    let remainder = ticks % divisor
    let (wholeNanos, overflow) = whole.multipliedReportingOverflow(by: multiplier)
    if overflow { return UInt64.max }
    return wholeNanos + (remainder * multiplier) / divisor
}

struct ProcessSample {
    let pid: pid_t
    let ppid: pid_t
    let name: String
    let path: String
    let args: String
    let residentBytes: UInt64
    let physicalFootprintBytes: UInt64
    let peakPhysicalFootprintBytes: UInt64
    let cpuNanos: UInt64
    let lifetimeCpuNanos: UInt64
    let diskReadBytes: UInt64
    let diskWriteBytes: UInt64
    let idleWakeups: UInt64
    let startTime: TimeInterval
    let status: Int32
    var cpuPercent: Double = 0

    var searchText: String {
        "\(name) \(path) \(args)".lowercased()
    }

    var memoryBytes: UInt64 {
        physicalFootprintBytes > 0 ? physicalFootprintBytes : residentBytes
    }

}

struct CPUTicks {
    let busy: UInt64
    let idle: UInt64
}

struct InterfaceCounters {
    let receivedBytes: UInt64
    let sentBytes: UInt64
}

struct ProcessSnapshot {
    let processes: [ProcessSample]
    let processCount: Int
    let zombieCount: Int
    let systemBusyPercent: Double?
    let interfaceRates: [String: (received: Double, sent: Double)]
}

struct ProcessCollection {
    let samples: [ProcessSample]
    let processCount: Int
    let zombieCount: Int
}

struct DefaultRoute {
    let interface: String
    let gateway: String?
}

struct ParsedRouteMessage {
    let interfaceIndex: UInt32
    let gateway: String?
}

struct Snapshot {
    let mode: String
    let timestamp: String
    let host: String
    let storage: String
    let cpu: String
    let security: String
    let memory: String
    let power: String
    let thermals: String
    let network: String
    let wifi: String
    let codex: String
    let codexResources: String
    let lifecycle: String
    let browserAutomation: String
    let attention: AttentionAssessment
    let collection: String

    func jsonObject() -> [String: Any] {
        var object: [String: Any] = [
            "hook_version": currentHookVersion(),
            "mode": mode,
            "timestamp": timestamp,
            "host": host,
            "storage": storage,
            "cpu": cpu,
            "security": security,
            "memory": memory,
            "power": power,
            "thermals": thermals,
            "codex": codex,
            "codex_resources": codexResources,
            "lifecycle": lifecycle,
            "browser_automation": browserAutomation,
            "attention": [
                "required": attention.required,
                "reasons": attention.reasons.map { ["code": $0.code, "summary": $0.summary] }
            ],
            "collection": collection
        ]
        if !network.isEmpty { object["network"] = network }
        if !wifi.isEmpty { object["wifi"] = wifi }
        return object
    }
}

func isoTimestamp() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: Date())
}

func hostname() -> String {
    var buffer = [CChar](repeating: 0, count: 256)
    if gethostname(&buffer, buffer.count) == 0 {
        return stringFromCStringBuffer(buffer)
    }
    return "unknown"
}

func stringFromCStringBuffer(_ buffer: [CChar]) -> String {
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
}

func formatGB(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / 1_000_000_000
    if gb >= 100 {
        return "\(Int(gb.rounded()))G"
    }
    return String(format: "%.1fG", gb)
}

func formatMB(_ bytes: UInt64) -> String {
    let mb = Double(bytes) / 1_000_000
    if mb >= 100 {
        return "\(Int(mb.rounded()))MB"
    }
    return String(format: "%.1fMB", mb)
}

func formatBytes(_ bytes: UInt64) -> String {
    if bytes >= 1_000_000_000 {
        return formatGB(bytes)
    }
    if bytes >= 1_000_000 {
        return formatMB(bytes)
    }
    if bytes >= 1_000 {
        return "\(Int((Double(bytes) / 1_000).rounded()))KB"
    }
    return "\(bytes)B"
}

func formatRate(_ bytesPerSecond: Double) -> String {
    guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "0B/s" }
    return "\(formatBytes(UInt64(bytesPerSecond.rounded())))/s"
}

func formatCountRate(_ value: Double) -> String {
    guard value.isFinite, value > 0 else { return "0/s" }
    if value >= 10 {
        return "\(Int(value.rounded()))/s"
    }
    return String(format: "%.1f/s", value)
}

func formatPercent(_ value: Double) -> String {
    if value >= 10 {
        return "\(Int(value.rounded()))%"
    }
    return String(format: "%.1f%%", value)
}

func formatMilliseconds(_ value: Double?) -> String {
    guard let value else { return "unknown" }
    if value >= 100 {
        return "\(Int(value.rounded()))ms"
    }
    return String(format: "%.1fms", value)
}

func formatAge(_ seconds: TimeInterval) -> String {
    if seconds <= 0 {
        return "0m"
    }
    let totalMinutes = Int(seconds / 60)
    if totalMinutes >= 60 {
        return "\(totalMinutes / 60)h\(totalMinutes % 60)m"
    }
    if totalMinutes > 0 {
        return "\(totalMinutes)m"
    }
    return "\(Int(seconds))s"
}

func storageStatus() -> StorageStatus {
    var fs = statfs()
    if statfs(NSHomeDirectory(), &fs) == 0, fs.f_blocks > 0 {
        let blockSize = UInt64(fs.f_bsize)
        let total = UInt64(fs.f_blocks) * blockSize
        let available = UInt64(fs.f_bavail) * blockSize
        let used = total > available ? total - available : 0
        let usedPercent = Double(used) / Double(total) * 100
        return StorageStatus(usedPercent: usedPercent, freeBytes: available)
    }
    return StorageStatus(usedPercent: nil, freeBytes: nil)
}

func processName(pid: pid_t) -> String {
    var buffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) + 1)
    let length = buffer.withUnsafeMutableBufferPointer { pointer in
        proc_name(pid, pointer.baseAddress, UInt32(pointer.count))
    }
    if length > 0 {
        return stringFromCStringBuffer(buffer)
    }
    return "unknown"
}

func stringFromCCharTuple<T>(_ tuple: T) -> String {
    withUnsafeBytes(of: tuple) { rawBuffer in
        let bytes = rawBuffer.bindMemory(to: CChar.self)
        var chars: [CChar] = []
        chars.reserveCapacity(bytes.count + 1)
        for byte in bytes {
            if byte == 0 { break }
            chars.append(byte)
        }
        return stringFromCStringBuffer(chars)
    }
}

func processPath(pid: pid_t) -> String {
    var buffer = [CChar](repeating: 0, count: 4096)
    let length = buffer.withUnsafeMutableBufferPointer { pointer in
        proc_pidpath(pid, pointer.baseAddress, UInt32(pointer.count))
    }
    if length > 0 {
        return stringFromCStringBuffer(buffer)
    }
    return ""
}

func parsedProcessArguments(_ buffer: [UInt8]) -> [String] {
    let integerSize = MemoryLayout<Int32>.size
    guard buffer.count >= integerSize else { return [] }

    let argumentCount = buffer.withUnsafeBytes { rawBuffer -> Int in
        Int(rawBuffer.loadUnaligned(as: Int32.self))
    }
    guard argumentCount > 0, argumentCount <= 4_096 else { return [] }

    var index = integerSize
    while index < buffer.count, buffer[index] != 0 { index += 1 }
    while index < buffer.count, buffer[index] == 0 { index += 1 }

    var arguments: [String] = []
    arguments.reserveCapacity(argumentCount)
    for _ in 0..<argumentCount {
        guard index < buffer.count else { break }
        let start = index
        while index < buffer.count, buffer[index] != 0 { index += 1 }
        arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
        if index < buffer.count { index += 1 }
    }
    return arguments
}

func processArguments(pid: pid_t) -> String {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    if sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) != 0 || size <= 0 {
        return ""
    }

    var buffer = [UInt8](repeating: 0, count: size)
    if sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) != 0 || size <= MemoryLayout<Int32>.size {
        return ""
    }

    return parsedProcessArguments(Array(buffer.prefix(size))).joined(separator: " ")
}

func bsdInfo(pid: pid_t) -> proc_bsdinfo? {
    var info = proc_bsdinfo()
    let size = MemoryLayout<proc_bsdinfo>.stride
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, Int32(size))
    }
    return result == Int32(size) ? info : nil
}

func taskInfo(pid: pid_t) -> proc_taskinfo? {
    var info = proc_taskinfo()
    let size = MemoryLayout<proc_taskinfo>.stride
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        proc_pidinfo(pid, PROC_PIDTASKINFO, 0, pointer, Int32(size))
    }
    return result == Int32(size) ? info : nil
}

func resourceUsage(pid: pid_t) -> rusage_info_v4? {
    var info = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
        }
    }
    return result == 0 ? info : nil
}

func shouldReadArguments(name: String, path: String) -> Bool {
    let text = "\(name) \(path)".lowercased()
    return text.contains("codex")
        || text.contains("node")
        || text.contains("npm")
        || text.contains("mcp")
        || text.contains("xcodebuild")
        || text.contains("chrome")
        || text.contains("chromedriver")
        || text.contains("playwright")
        || text.contains("discord")
        || text.contains("skycomputer")
        || containsDelimitedIdentifier("computer-use", in: text)
        || containsDelimitedIdentifier("computer_use", in: text)
        || containsDelimitedIdentifier("cua_node", in: text)
        || text.contains("screencapture")
}

func shouldCollectDetailedUsage(name: String, path: String, args: String) -> Bool {
    let identity = "\(name) \(path)".lowercased()
    let details = args.lowercased()
    return name.lowercased() == "chatgpt"
        || name.lowercased() == "codex"
        || identity.contains("/applications/chatgpt.app")
        || identity.contains("/applications/codex.app")
        || identity.contains("node")
        || identity.contains("npm")
        || identity.contains("mcp")
        || identity.contains("xcodebuild")
        || identity.contains("syspolicyd")
        || identity.contains("trustd")
        || identity.contains("sandboxd")
        || identity.contains("skycomputer")
        || containsDelimitedIdentifier("computer-use", in: identity)
        || containsDelimitedIdentifier("computer_use", in: identity)
        || containsDelimitedIdentifier("cua_node", in: identity)
        || details.contains("node_repl")
        || containsDelimitedIdentifier("computer-use", in: details)
        || containsDelimitedIdentifier("computer_use", in: details)
        || containsDelimitedIdentifier("cua_node", in: details)
        || isBrowserAutomationIdentity(identity: identity, arguments: details)
}

func containsDelimitedIdentifier(_ identifier: String, in text: String) -> Bool {
    guard !identifier.isEmpty else { return false }
    var searchStart = text.startIndex
    while searchStart < text.endIndex,
          let range = text.range(of: identifier, range: searchStart..<text.endIndex) {
        let leftIsIdentifier = range.lowerBound > text.startIndex
            && isIdentifierCharacter(text[text.index(before: range.lowerBound)])
        let rightIsIdentifier = range.upperBound < text.endIndex
            && isIdentifierCharacter(text[range.upperBound])
        if !leftIsIdentifier && !rightIsIdentifier {
            return true
        }
        searchStart = range.upperBound
    }
    return false
}

private func isIdentifierCharacter(_ character: Character) -> Bool {
    character.isLetter || character.isNumber || character == "_" || character == "-"
}

func isBrowserAutomationIdentity(identity: String, arguments: String) -> Bool {
    let text = "\(identity) \(arguments)".lowercased()
    return text.contains("--headless")
        || text.contains("--remote-debugging-port=")
        || text.contains("--remote-debugging-pipe")
        || text.contains("chrome-headless-shell")
        || text.contains("chromedriver")
        || text.contains("playwright")
        || text.contains("puppeteer")
}

func isBrowserAutomationProcess(_ process: ProcessSample) -> Bool {
    isBrowserAutomationIdentity(
        identity: "\(process.name) \(process.path)",
        arguments: process.args
    )
}

func listedProcessIDs() -> [pid_t] {
    let pidByteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
    guard pidByteCount > 0 else { return [] }

    let capacity = Int(pidByteCount) / MemoryLayout<pid_t>.stride
    var pids = [pid_t](repeating: 0, count: capacity)
    let actualByteCount = pids.withUnsafeMutableBufferPointer { pointer in
        proc_listpids(UInt32(PROC_ALL_PIDS), 0, pointer.baseAddress, pidByteCount)
    }
    let count = max(0, Int(actualByteCount) / MemoryLayout<pid_t>.stride)
    return Array(pids.prefix(count).filter { $0 > 0 })
}

func collectCPUTimes() -> [pid_t: UInt64] {
    var times: [pid_t: UInt64] = [:]
    for pid in listedProcessIDs() {
        guard let task = taskInfo(pid: pid) else { continue }
        let ticks = UInt64(task.pti_total_user) + UInt64(task.pti_total_system)
        times[pid] = nanosecondsFromMachTicks(ticks)
    }
    return times
}

func collectProcesses(includeArguments: Bool, includeDetailedUsage: Bool) -> ProcessCollection {
    let pids = listedProcessIDs()

    var samples: [ProcessSample] = []
    samples.reserveCapacity(pids.count)
    var processCount = 0
    var zombieCount = 0

    for pid in pids {
        guard let bsd = bsdInfo(pid: pid) else { continue }
        processCount += 1
        let status = Int32(bitPattern: bsd.pbi_status)
        if status == SZOMB {
            zombieCount += 1
            continue
        }
        guard let task = taskInfo(pid: pid) else { continue }
        let bsdName = stringFromCCharTuple(bsd.pbi_name)
        let name = bsdName.isEmpty ? processName(pid: pid) : bsdName
        let path = processPath(pid: pid)
        let args = includeArguments && shouldReadArguments(name: name, path: path) ? processArguments(pid: pid) : ""
        let usage = includeDetailedUsage && shouldCollectDetailedUsage(name: name, path: path, args: args)
            ? resourceUsage(pid: pid)
            : nil
        let taskCPUTicks = UInt64(task.pti_total_user) + UInt64(task.pti_total_system)
        let usageCPUTicks = usage.map { $0.ri_user_time + $0.ri_system_time } ?? 0
        let taskCPUNanos = nanosecondsFromMachTicks(taskCPUTicks)
        let usageCPUNanos = nanosecondsFromMachTicks(usageCPUTicks)
        samples.append(ProcessSample(
            pid: pid,
            ppid: pid_t(bitPattern: bsd.pbi_ppid),
            name: name,
            path: path,
            args: args,
            residentBytes: UInt64(task.pti_resident_size),
            physicalFootprintBytes: usage?.ri_phys_footprint ?? 0,
            peakPhysicalFootprintBytes: usage?.ri_lifetime_max_phys_footprint ?? 0,
            cpuNanos: taskCPUNanos,
            lifetimeCpuNanos: usageCPUNanos > 0 ? usageCPUNanos : taskCPUNanos,
            diskReadBytes: usage?.ri_diskio_bytesread ?? 0,
            diskWriteBytes: usage?.ri_diskio_byteswritten ?? 0,
            idleWakeups: usage.map { $0.ri_pkg_idle_wkups + $0.ri_interrupt_wkups } ?? 0,
            startTime: TimeInterval(bsd.pbi_start_tvsec),
            status: status
        ))
    }

    return ProcessCollection(samples: samples, processCount: processCount, zombieCount: zombieCount)
}

func cpuTicks() -> CPUTicks? {
    var info = host_cpu_load_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
    )
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return nil }

    let user = UInt64(info.cpu_ticks.0)
    let system = UInt64(info.cpu_ticks.1)
    let idle = UInt64(info.cpu_ticks.2)
    let nice = UInt64(info.cpu_ticks.3)
    return CPUTicks(busy: user + system + nice, idle: idle)
}

func interfaceCounters() -> [String: InterfaceCounters] {
    var addresses: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addresses) == 0, let first = addresses else {
        return [:]
    }
    defer { freeifaddrs(addresses) }

    var counters: [String: InterfaceCounters] = [:]
    var pointer: UnsafeMutablePointer<ifaddrs>? = first
    while let current = pointer {
        defer { pointer = current.pointee.ifa_next }
        guard let data = current.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) else {
            continue
        }
        let name = String(cString: current.pointee.ifa_name)
        counters[name] = InterfaceCounters(
            receivedBytes: UInt64(data.pointee.ifi_ibytes),
            sentBytes: UInt64(data.pointee.ifi_obytes)
        )
    }
    return counters
}

func sampledProcesses(whileWaiting: (() -> Void)? = nil) -> ProcessSnapshot {
    let sampleStartedAt = DispatchTime.now().uptimeNanoseconds
    let beforeCPUTicks = cpuTicks()
    let beforeInterfaces = interfaceCounters()
    let beforeCPU = collectCPUTimes()
    whileWaiting?()
    let workElapsed = Double(DispatchTime.now().uptimeNanoseconds - sampleStartedAt) / 1_000_000_000
    if workElapsed < 0.10 {
        Thread.sleep(forTimeInterval: 0.10 - workElapsed)
    }
    let secondSampleStartedAt = DispatchTime.now().uptimeNanoseconds
    let afterCPUTicks = cpuTicks()
    let afterInterfaces = interfaceCounters()
    let after = collectProcesses(includeArguments: true, includeDetailedUsage: true)
    let elapsedNanos = max(Double(secondSampleStartedAt - sampleStartedAt), 1)
    let elapsedSeconds = elapsedNanos / 1_000_000_000

    let processes = after.samples.map { sample in
        var updated = sample
        if let previous = beforeCPU[sample.pid], sample.cpuNanos >= previous {
            updated.cpuPercent = Double(sample.cpuNanos - previous) / elapsedNanos * 100
        }
        return updated
    }

    let systemBusyPercent: Double?
    if let beforeCPUTicks, let afterCPUTicks,
       afterCPUTicks.busy >= beforeCPUTicks.busy,
       afterCPUTicks.idle >= beforeCPUTicks.idle {
        let busy = afterCPUTicks.busy - beforeCPUTicks.busy
        let idle = afterCPUTicks.idle - beforeCPUTicks.idle
        let total = busy + idle
        systemBusyPercent = total > 0 ? Double(busy) / Double(total) * 100 : nil
    } else {
        systemBusyPercent = nil
    }

    var interfaceRates: [String: (received: Double, sent: Double)] = [:]
    for (name, afterCounters) in afterInterfaces {
        guard let beforeCounters = beforeInterfaces[name] else { continue }
        let received = afterCounters.receivedBytes >= beforeCounters.receivedBytes
            ? Double(afterCounters.receivedBytes - beforeCounters.receivedBytes) / elapsedSeconds
            : 0
        let sent = afterCounters.sentBytes >= beforeCounters.sentBytes
            ? Double(afterCounters.sentBytes - beforeCounters.sentBytes) / elapsedSeconds
            : 0
        interfaceRates[name] = (received, sent)
    }

    return ProcessSnapshot(
        processes: processes,
        processCount: after.processCount,
        zombieCount: after.zombieCount,
        systemBusyPercent: systemBusyPercent,
        interfaceRates: interfaceRates
    )
}

func helperKind(_ process: ProcessSample) -> String? {
    let text = process.searchText
    if text.contains("codex app-server") || text.contains("/codex app-server") { return "app_server" }
    if text.contains("node_repl") { return "node_repl" }
    if text.contains("xcodebuildmcp") { return "xcodebuildmcp" }
    if containsDelimitedIdentifier("computer-use", in: text)
        || containsDelimitedIdentifier("computer_use", in: text)
        || containsDelimitedIdentifier("skycomputeruse", in: text)
        || containsDelimitedIdentifier("cua_node", in: text) {
        return "computer_use"
    }
    if text.contains("mcp") && (text.contains("codex") || text.contains("node")) { return "mcp" }
    if isBrowserAutomationProcess(process) {
        return "browser_automation"
    }
    return nil
}

func friendlyProcessName(_ process: ProcessSample) -> String {
    if let helper = helperKind(process) {
        return helper
    }
    let path = process.path
    if let range = path.range(of: ".app/Contents") {
        let prefix = path[..<range.lowerBound]
        if let appPart = prefix.split(separator: "/").last {
            return String(appPart).replacingOccurrences(of: ".app", with: "")
        }
    }
    if process.name != "unknown" {
        return process.name.replacingOccurrences(of: " Helper", with: "")
    }
    return "unknown"
}

func processLabel(_ process: ProcessSample) -> String {
    "\(friendlyProcessName(process))[\(process.pid)]"
}

func processAge(_ process: ProcessSample) -> String {
    formatAge(Date().timeIntervalSince1970 - process.startTime)
}

func processMemorySummary(_ process: ProcessSample) -> String {
    var summary = formatBytes(process.memoryBytes)
    if process.peakPhysicalFootprintBytes > 0 {
        summary += "/peak=\(formatBytes(process.peakPhysicalFootprintBytes))"
    }
    return summary
}

func topCPULine(_ processes: [ProcessSample], systemBusyPercent: Double?) -> String {
    var loads = [Double](repeating: 0, count: 3)
    let loadPart: String
    if getloadavg(&loads, 3) == 3 {
        loadPart = String(format: "load=%.2f/%.2f/%.2f", loads[0], loads[1], loads[2])
    } else {
        loadPart = "load=unknown"
    }

    let cores = ProcessInfo.processInfo.activeProcessorCount
    let busyPart = systemBusyPercent.map { "busy=\(formatPercent($0))" } ?? "busy=unknown"
    let top = processes
        .filter { !$0.searchText.contains("system-health-context") }
        .filter { $0.cpuPercent >= 0.05 }
        .sorted { $0.cpuPercent > $1.cpuPercent }
        .prefix(3)
        .map { "\(processLabel($0)):\(formatPercent($0.cpuPercent))/\(processAge($0))" }
        .joined(separator: ", ")

    return "cores=\(cores) \(busyPart) \(loadPart) top=\(top.isEmpty ? "none" : top)"
}

func securityStatus(_ processes: [ProcessSample]) -> SecurityStatus {
    var syspolicyd = 0.0
    var trustd = 0.0
    var sandboxd = 0.0

    for process in processes {
        let text = "\(process.name) \(process.path)".lowercased()
        if text.contains("syspolicyd") {
            syspolicyd += process.cpuPercent
        } else if text.contains("sandboxd") {
            sandboxd += process.cpuPercent
        } else if text.contains("trustd") {
            trustd += process.cpuPercent
        }
    }

    return SecurityStatus(
        syspolicydCPU: syspolicyd,
        trustdCPU: trustd,
        sandboxdCPU: sandboxd
    )
}

func memoryStatus() -> MemoryStatus {
    var pageSize: vm_size_t = 0
    host_page_size(mach_host_self(), &pageSize)

    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
    let result = withUnsafeMutablePointer(to: &stats) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }

    var pressureLevel: Int32 = 0
    var pressureSize = MemoryLayout<Int32>.stride
    let pressure: MemoryPressureLevel
    if sysctlbyname("kern.memorystatus_vm_pressure_level", &pressureLevel, &pressureSize, nil, 0) == 0 {
        switch pressureLevel {
        case 1: pressure = .normal
        case 2: pressure = .warning
        case 4: pressure = .critical
        default: pressure = .unknown
        }
    } else {
        pressure = .unknown
    }

    var parts = ["ram=\(formatGB(ProcessInfo.processInfo.physicalMemory))"]
    if result == KERN_SUCCESS {
        let pageBytes = UInt64(pageSize)
        parts.append("free=\(formatGB(UInt64(stats.free_count) * pageBytes))")
        parts.append("inactive=\(formatGB(UInt64(stats.inactive_count) * pageBytes))")
        parts.append("compressed=\(formatGB(UInt64(stats.compressor_page_count) * pageBytes))")
        parts.append("wired=\(formatGB(UInt64(stats.wire_count) * pageBytes))")
    } else {
        parts.append("free=unknown")
    }

    var swap = xsw_usage()
    var swapSize = MemoryLayout<xsw_usage>.stride
    if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
        parts.append("swap=\(formatGB(UInt64(swap.xsu_used)))")
    }

    return MemoryStatus(pressure: pressure, detail: parts.joined(separator: " "))
}

func topMemoryLine(_ processes: [ProcessSample]) -> String {
    let top = processes
        .filter { $0.memoryBytes > 0 }
        .sorted { $0.memoryBytes > $1.memoryBytes }
        .prefix(3)
        .map { process in
            "\(processLabel(process)):\(processMemorySummary(process))/\(processAge(process))"
        }
        .joined(separator: ", ")
    return top.isEmpty ? "top=unknown" : "top=\(top)"
}

func powerLine() -> String {
    var source = "unknown"
    var battery = "unknown"
    var charging = "unknown"

    if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
       let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
        for item in list {
            guard let description = IOPSGetPowerSourceDescription(info, item)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            if let current = description[kIOPSCurrentCapacityKey as String] as? Int,
               let max = description[kIOPSMaxCapacityKey as String] as? Int,
               max > 0 {
                battery = "\(Int((Double(current) / Double(max) * 100).rounded()))%"
            }
            if let state = description[kIOPSPowerSourceStateKey as String] as? String {
                source = state == kIOPSACPowerValue ? "AC" : state
            }
            if let isCharging = description[kIOPSIsChargingKey as String] as? Bool {
                charging = isCharging ? "charging" : "not_charging"
            }
            break
        }
    }

    let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off"
    return "source=\(source) battery=\(battery) charging=\(charging) low_power=\(lowPower)"
}

func primaryInterface() -> String? {
    guard let store = SCDynamicStoreCreate(nil, "system-health-context" as CFString, nil, nil),
          let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] else {
        return nil
    }
    return value["PrimaryInterface"] as? String
}

func activeIPv4Interface() -> String? {
    var addresses: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addresses) == 0, let first = addresses else {
        return nil
    }
    defer { freeifaddrs(addresses) }

    var fallback: String?
    var pointer: UnsafeMutablePointer<ifaddrs>? = first
    while let current = pointer {
        defer { pointer = current.pointee.ifa_next }
        guard let addr = current.pointee.ifa_addr,
              addr.pointee.sa_family == UInt8(AF_INET) else {
            continue
        }

        let flags = Int32(current.pointee.ifa_flags)
        let isUp = (flags & IFF_UP) != 0
        let isLoopback = (flags & IFF_LOOPBACK) != 0
        guard isUp, !isLoopback else {
            continue
        }

        let name = String(cString: current.pointee.ifa_name)
        if name == "en0" {
            return name
        }
        fallback = fallback ?? name
    }
    return fallback
}

func routeSockaddrLength(_ length: Int) -> Int {
    let alignment = MemoryLayout<UInt32>.stride
    return max(alignment, (length + alignment - 1) & ~(alignment - 1))
}

func ipv4AddressString(_ address: in_addr) -> String? {
    var address = address
    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    let result = withUnsafePointer(to: &address) { pointer in
        inet_ntop(AF_INET, pointer, &buffer, socklen_t(buffer.count))
    }
    return result == nil ? nil : stringFromCStringBuffer(buffer)
}

func parsedRouteMessage(_ bytes: [UInt8]) -> ParsedRouteMessage? {
    let headerSize = MemoryLayout<rt_msghdr>.stride
    guard bytes.count >= headerSize else { return nil }
    let header = bytes.withUnsafeBytes { $0.loadUnaligned(as: rt_msghdr.self) }
    let messageLength = min(Int(header.rtm_msglen), bytes.count)
    guard header.rtm_version == UInt8(RTM_VERSION), messageLength >= headerSize else { return nil }

    var gateway: String?
    var offset = headerSize
    for addressIndex in 0..<Int(RTAX_MAX) {
        let mask = Int32(1 << addressIndex)
        guard (header.rtm_addrs & mask) != 0 else { continue }
        guard offset + 2 <= messageLength else { return nil }
        let length = Int(bytes[offset])
        let family = Int32(bytes[offset + 1])
        let paddedLength = routeSockaddrLength(length)
        guard offset + paddedLength <= messageLength else { return nil }

        if addressIndex == Int(RTAX_GATEWAY), family == AF_INET,
           length >= MemoryLayout<sockaddr_in>.stride {
            let address = bytes.withUnsafeBytes { rawBuffer -> sockaddr_in in
                rawBuffer.loadUnaligned(fromByteOffset: offset, as: sockaddr_in.self)
            }
            gateway = ipv4AddressString(address.sin_addr)
        }
        offset += paddedLength
    }

    return ParsedRouteMessage(interfaceIndex: UInt32(header.rtm_index), gateway: gateway)
}

func interfaceName(index: UInt32) -> String? {
    guard index > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: Int(IFNAMSIZ))
    return if_indextoname(index, &buffer).map { _ in stringFromCStringBuffer(buffer) }
}

func kernelDefaultRoute() -> DefaultRoute? {
    let fd = socket(PF_ROUTE, SOCK_RAW, AF_UNSPEC)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

    let headerSize = MemoryLayout<rt_msghdr>.stride
    let destinationSize = MemoryLayout<sockaddr_in>.stride
    var request = [UInt8](repeating: 0, count: headerSize + destinationSize)
    let requestSize = request.count
    let sequence = Int32(truncatingIfNeeded: DispatchTime.now().uptimeNanoseconds)
    let processID = getpid()

    request.withUnsafeMutableBytes { rawBuffer in
        let header = rawBuffer.baseAddress!.assumingMemoryBound(to: rt_msghdr.self)
        header.pointee.rtm_msglen = UInt16(requestSize)
        header.pointee.rtm_version = UInt8(RTM_VERSION)
        header.pointee.rtm_type = UInt8(RTM_GET)
        header.pointee.rtm_addrs = RTA_DST
        header.pointee.rtm_pid = processID
        header.pointee.rtm_seq = sequence

        let destination = rawBuffer.baseAddress!
            .advanced(by: headerSize)
            .assumingMemoryBound(to: sockaddr_in.self)
        destination.pointee.sin_len = UInt8(destinationSize)
        destination.pointee.sin_family = sa_family_t(AF_INET)
        destination.pointee.sin_addr = in_addr(s_addr: INADDR_ANY)
    }

    let written = request.withUnsafeBytes { rawBuffer in
        write(fd, rawBuffer.baseAddress, rawBuffer.count)
    }
    guard written == requestSize else { return nil }

    for _ in 0..<4 {
        var pollItem = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&pollItem, 1, 50) > 0 else { return nil }
        var reply = [UInt8](repeating: 0, count: 4096)
        let count = reply.withUnsafeMutableBytes { rawBuffer in
            read(fd, rawBuffer.baseAddress, rawBuffer.count)
        }
        guard count >= headerSize else { continue }
        reply.removeSubrange(Int(count)..<reply.count)
        let header = reply.withUnsafeBytes { $0.loadUnaligned(as: rt_msghdr.self) }
        guard header.rtm_pid == processID, header.rtm_seq == sequence else { continue }
        guard header.rtm_errno == 0,
              let parsed = parsedRouteMessage(reply),
              let interface = interfaceName(index: parsed.interfaceIndex) else {
            return nil
        }
        return DefaultRoute(interface: interface, gateway: parsed.gateway)
    }
    return nil
}

func tcpConnectLatency(host: String, port: Int32, timeoutMillis: Int32) -> Double? {
    var hints = addrinfo()
    hints.ai_family = AF_INET
    hints.ai_socktype = SOCK_STREAM
    hints.ai_protocol = IPPROTO_TCP
    hints.ai_flags = AI_NUMERICHOST

    var result: UnsafeMutablePointer<addrinfo>?
    let service = "\(port)"
    guard getaddrinfo(host, service, &hints, &result) == 0, let result else {
        return nil
    }
    defer { freeaddrinfo(result) }

    let fd = socket(result.pointee.ai_family, result.pointee.ai_socktype, result.pointee.ai_protocol)
    guard fd >= 0 else { return nil }
    defer { close(fd) }

    let flags = fcntl(fd, F_GETFL, 0)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

    let start = DispatchTime.now().uptimeNanoseconds
    let connectResult = connect(fd, result.pointee.ai_addr, result.pointee.ai_addrlen)
    if connectResult == 0 {
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    if errno != EINPROGRESS && errno != EWOULDBLOCK {
        return nil
    }

    var pollItem = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    let pollResult = poll(&pollItem, 1, timeoutMillis)
    if pollResult <= 0 {
        return nil
    }

    var socketError: Int32 = 0
    var length = socklen_t(MemoryLayout<Int32>.stride)
    if getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) != 0 {
        return nil
    }

    if socketError == 0 || socketError == ECONNREFUSED {
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }
    return nil
}

func wifiLineAndInterface() -> (line: String, interface: String?) {
    guard let interface = CWWiFiClient.shared().interface() else {
        let fallback = activeIPv4Interface()
        return ("interface=\(fallback ?? "unknown")", fallback)
    }

    let name = interface.interfaceName ?? "unknown"
    var parts = ["interface=\(name)"]
    let rssi = interface.rssiValue()
    let noise = interface.noiseMeasurement()
    let tx = interface.transmitRate()
    let channel = interface.wlanChannel()?.channelNumber
    let associated = interface.ssid() != nil || rssi != 0 || tx > 0 || channel != nil ? "yes" : "no"
    parts.append("associated=\(associated)")
    if rssi != 0 {
        parts.append("rssi=\(rssi)dBm")
    }
    if noise != 0 {
        parts.append("noise=\(noise)dBm")
    }
    if let channel {
        parts.append("channel=\(channel)")
    }
    if tx > 0 {
        parts.append("tx=\(Int(tx.rounded()))Mbps")
    }

    return (parts.joined(separator: " "), name == "unknown" ? nil : name)
}

func networkLine(route: DefaultRoute?, rates: [String: (received: Double, sent: Double)]) -> String {
    let active = route?.interface ?? primaryInterface() ?? activeIPv4Interface() ?? "unknown"
    let gateway = route?.gateway
    let gatewayLatency = gateway.flatMap { tcpConnectLatency(host: $0, port: 80, timeoutMillis: 250) }
    let wanLatency = tcpConnectLatency(host: "1.1.1.1", port: 443, timeoutMillis: 300)
    var parts = ["route=\(active)"]
    if let rate = rates[active] {
        parts.append("rx=\(formatRate(rate.received))")
        parts.append("tx=\(formatRate(rate.sent))")
    }
    if let gateway {
        parts.append("gateway=\(gateway)")
    }
    if gatewayLatency != nil {
        parts.append("gateway_tcp=\(formatMilliseconds(gatewayLatency))")
    }
    if wanLatency != nil {
        parts.append("wan_tcp=\(formatMilliseconds(wanLatency))")
    }
    return parts.joined(separator: " ")
}

func maxAgeText(_ processes: [ProcessSample]) -> String {
    let now = Date().timeIntervalSince1970
    let maxAge = processes.map { now - $0.startTime }.max() ?? 0
    return formatAge(maxAge)
}

func codexHelperProcesses(_ processes: [ProcessSample]) -> [ProcessSample] {
    processes.filter { process in
        guard let kind = helperKind(process) else { return false }
        return kind == "node_repl" || kind == "xcodebuildmcp" || kind == "computer_use" || kind == "mcp"
    }
}

func helperBuckets(_ processes: [ProcessSample]) -> [String: [ProcessSample]] {
    var buckets: [String: [ProcessSample]] = [
        "mcp": [],
        "node_repl": [],
        "computer_use": [],
        "xcodebuildmcp": [],
        "app_server": []
    ]
    for process in processes {
        guard let kind = helperKind(process), buckets[kind] != nil else { continue }
        buckets[kind, default: []].append(process)
    }
    return buckets
}

func isCodexHostProcess(_ process: ProcessSample) -> Bool {
    let text = process.searchText
    return text.contains("/applications/codex.app")
        || text.contains("/applications/chatgpt.app")
        || process.name.lowercased() == "codex"
        || process.name.lowercased() == "chatgpt"
}

func codexHostProcesses(_ processes: [ProcessSample]) -> [ProcessSample] {
    processes.filter(isCodexHostProcess)
}

func codexRelevantProcesses(_ processes: [ProcessSample]) -> [ProcessSample] {
    processes.filter { process in
        if helperKind(process) != nil { return true }
        return isCodexHostProcess(process)
    }
}

func lifetimeAverageCPU(
    _ process: ProcessSample,
    now: TimeInterval = Date().timeIntervalSince1970
) -> Double {
    let age = now - process.startTime
    guard age > 0 else { return 0 }
    return Double(process.lifetimeCpuNanos) / (age * 1_000_000_000) * 100
}

func lifetimeAverageRate(
    bytes: UInt64,
    process: ProcessSample,
    now: TimeInterval = Date().timeIntervalSince1970
) -> Double {
    let age = now - process.startTime
    guard age > 0 else { return 0 }
    return Double(bytes) / age
}

func lifetimeWakeupRate(
    _ process: ProcessSample,
    now: TimeInterval = Date().timeIntervalSince1970
) -> Double {
    let age = now - process.startTime
    guard age > 0 else { return 0 }
    return Double(process.idleWakeups) / age
}

func codexResourcesLine(_ processes: [ProcessSample]) -> String {
    let relevant = codexRelevantProcesses(processes)
    guard !relevant.isEmpty else { return "none" }

    let cpu = relevant.max {
        max($0.cpuPercent, lifetimeAverageCPU($0)) < max($1.cpuPercent, lifetimeAverageCPU($1))
    }
    let memory = relevant.max { $0.memoryBytes < $1.memoryBytes }
    let io = relevant.max {
        $0.diskReadBytes + $0.diskWriteBytes < $1.diskReadBytes + $1.diskWriteBytes
    }
    let wakeups = relevant.max { lifetimeWakeupRate($0) < lifetimeWakeupRate($1) }

    var parts: [String] = []
    if let cpu {
        parts.append("cpu=\(processLabel(cpu)):now=\(formatPercent(cpu.cpuPercent))/avg=\(formatPercent(lifetimeAverageCPU(cpu)))/age=\(processAge(cpu))")
    }
    if let memory {
        parts.append("memory=\(processLabel(memory)):\(processMemorySummary(memory))")
    }
    if let io {
        parts.append("io=\(processLabel(io)):read_avg=\(formatRate(lifetimeAverageRate(bytes: io.diskReadBytes, process: io)))/total=\(formatBytes(io.diskReadBytes))/write_avg=\(formatRate(lifetimeAverageRate(bytes: io.diskWriteBytes, process: io)))/total=\(formatBytes(io.diskWriteBytes))")
    }
    if let wakeups, lifetimeWakeupRate(wakeups) > 0 {
        parts.append("wakeups_avg=\(processLabel(wakeups)):\(formatCountRate(lifetimeWakeupRate(wakeups)))")
    }
    return parts.joined(separator: " ")
}

func codexLine(_ processes: [ProcessSample]) -> String {
    let codexProcesses = codexHostProcesses(processes)
    let buckets = helperBuckets(processes)

    let order = ["mcp", "node_repl", "computer_use", "xcodebuildmcp"]
    let helperCount = order.reduce(0) { $0 + (buckets[$1]?.count ?? 0) }
    let counts = order.map { "\($0)=\(buckets[$0]?.count ?? 0)" }.joined(separator: " ")
    let ages = order.compactMap { kind -> String? in
        guard let processes = buckets[kind], !processes.isEmpty else { return nil }
        return "\(kind)=\(maxAgeText(processes))"
    }.joined(separator: " ")
    let agePart = ages.isEmpty ? "" : " oldest=(\(ages))"

    return "hosts=\(codexProcesses.count) helpers=\(helperCount) (\(counts)) app_servers=\(buckets["app_server"]?.count ?? 0)\(agePart)"
}

func lifecycleLine(_ processes: [ProcessSample], processCount: Int, zombieCount: Int) -> String {
    let parentPID1Helpers = codexHelperProcesses(processes).filter { $0.ppid == 1 }.count
    return "uptime=\(formatAge(ProcessInfo.processInfo.systemUptime)) processes=\(processCount) zombies=\(zombieCount) parent_pid_1_helpers=\(parentPID1Helpers)"
}

func argumentValue(_ key: String, in arguments: String) -> String? {
    guard let keyRange = arguments.range(of: key) else { return nil }
    let suffix = arguments[keyRange.upperBound...]
    guard let first = suffix.first else { return "" }
    if first == "\"" || first == "'" {
        let valueStart = suffix.index(after: suffix.startIndex)
        guard let valueEnd = suffix[valueStart...].firstIndex(of: first) else {
            return String(suffix[valueStart...])
        }
        return String(suffix[valueStart..<valueEnd])
    }
    let valueEnd = suffix.firstIndex(where: { $0 == " " || $0 == "\t" }) ?? suffix.endIndex
    return String(suffix[..<valueEnd])
}

func browserAutomationLine(_ processes: [ProcessSample]) -> String {
    let profileProcesses = processes.filter(isBrowserAutomationProcess)
    let parentPID1 = profileProcesses.filter { $0.ppid == 1 }
    let profiles = Set(profileProcesses.compactMap { argumentValue("--user-data-dir=", in: $0.args) })
    let debugPorts = Set(profileProcesses.compactMap { argumentValue("--remote-debugging-port=", in: $0.args) })
    return "processes=\(profileProcesses.count) profiles=\(profiles.count) parent_pid_1=\(parentPID1.count) debug_ports=\(debugPorts.count)"
}

func renderText(_ snapshot: Snapshot) -> String {
    var lines = [
        "System Health Context",
        "",
        "Use this snapshot as operational context.",
        "Do not refuse work solely because of system health.",
        "If Attention is required, investigate the listed facts before adding more load. Do not wait for the user to notice.",
        "Do not recite healthy values.",
        "Helpers listed may belong to other active sessions; own only what this session started.",
        "At turn end, clean up only safe, clearly-owned resources.",
        "Ask before destructive cleanup.",
        "",
        "Attention: \(snapshot.attention.line)",
        "Header: hook_version=\(currentHookVersion()) mode=\(snapshot.mode) timestamp=\(snapshot.timestamp) host=\(snapshot.host)",
        "Storage: \(snapshot.storage)",
        "CPU: \(snapshot.cpu)",
        "Security: \(snapshot.security)",
        "Memory: \(snapshot.memory)",
        "Power: \(snapshot.power)",
        "Thermals: \(snapshot.thermals)"
    ]
    if !snapshot.network.isEmpty { lines.append("Network: \(snapshot.network)") }
    if !snapshot.wifi.isEmpty { lines.append("WiFi: \(snapshot.wifi)") }
    lines.append(contentsOf: [
        "Codex: \(snapshot.codex)",
        "CodexResources: \(snapshot.codexResources)",
        "Lifecycle: \(snapshot.lifecycle)",
        "BrowserAutomation: \(snapshot.browserAutomation)",
        "Collection: \(snapshot.collection)"
    ])
    return lines.joined(separator: "\n")
}

func collectSnapshot(mode: String, startedAt: UInt64, includeConnectivity: Bool = true) -> Snapshot {
    var thermals = ThermalSnapshot(readings: [], fans: nil, macOSState: macOSThermalState())
    let sampled = sampledProcesses {
        thermals = collectThermalSnapshot()
    }
    let processes = sampled.processes
    let storage = storageStatus()
    let security = securityStatus(processes)
    let memory = memoryStatus()
    let attention = assessAttention(
        storage: storage,
        memory: memory,
        security: security,
        thermals: thermals,
        processes: processes
    )
    let wifi = includeConnectivity ? wifiLineAndInterface() : (line: "", interface: nil)
    let route = includeConnectivity ? kernelDefaultRoute() : nil
    let network = includeConnectivity ? networkLine(route: route, rates: sampled.interfaceRates) : ""
    let durationMillis = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000

    return Snapshot(
        mode: mode,
        timestamp: isoTimestamp(),
        host: hostname(),
        storage: storage.line,
        cpu: topCPULine(processes, systemBusyPercent: sampled.systemBusyPercent),
        security: security.line,
        memory: "\(memory.line) \(topMemoryLine(processes))",
        power: powerLine(),
        thermals: thermals.line,
        network: network,
        wifi: wifi.line,
        codex: codexLine(processes),
        codexResources: codexResourcesLine(processes),
        lifecycle: lifecycleLine(
            processes,
            processCount: sampled.processCount,
            zombieCount: sampled.zombieCount
        ),
        browserAutomation: browserAutomationLine(processes),
        attention: attention,
        collection: String(format: "%.0fms", durationMillis)
    )
}

struct CodexStopHookInput: Decodable {
    let stopHookActive: Bool

    enum CodingKeys: String, CodingKey {
        case stopHookActive = "stop_hook_active"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stopHookActive = try container.decodeIfPresent(Bool.self, forKey: .stopHookActive) ?? false
    }
}

func decodeStopHookActive(_ data: Data) -> Bool {
    guard !data.isEmpty,
          let decoded = try? JSONDecoder().decode(CodexStopHookInput.self, from: data) else {
        return false
    }
    return decoded.stopHookActive
}

func stopContinuationReason(_ assessment: AttentionAssessment) -> String {
    let facts = assessment.reasons.map(\.summary).joined(separator: "; ")
    return """
    Continue the current task. Before finishing, investigate only the listed health signal far enough to decide whether this work is causing it: \(facts). Adapt the work or clean up safe, clearly-owned leftovers from this task if needed. Then finish the original request. Do not replace the requested result with a system-health report. Mention system health only if it affected the work or requires user action. Do not terminate resources that may belong to another active task.
    """
}

func codexHookOutput(mode: String, snapshot: Snapshot, stopHookActive: Bool = false) -> [String: Any] {
    if mode == "turn_end" {
        guard snapshot.attention.required, !stopHookActive else { return [:] }
        return [
            "decision": "block",
            "reason": stopContinuationReason(snapshot.attention)
        ]
    }
    return [
        "hookSpecificOutput": [
            "hookEventName": "UserPromptSubmit",
            "additionalContext": renderText(snapshot)
        ]
    ]
}

func printJSON(_ object: [String: Any], pretty: Bool = false) throws {
    let options: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
    let data = try JSONSerialization.data(withJSONObject: object, options: options)
    print(String(data: data, encoding: .utf8) ?? "{}")
}

let args = CommandLine.arguments.dropFirst()
if args.contains("--version") {
    print(currentHookVersion())
    exit(0)
}

let outputJSON = args.contains("--json")
let codexHook = args.contains("--codex-hook")
let mode = args.first { $0 == "turn_start" || $0 == "turn_end" } ?? "turn_start"
var stopHookActive = false
if codexHook, mode == "turn_end" {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    stopHookActive = decodeStopHookActive(input)
    if stopHookActive {
        try printJSON([:])
        exit(0)
    }
}

let startedAt = DispatchTime.now().uptimeNanoseconds
let snapshot = collectSnapshot(
    mode: mode,
    startedAt: startedAt,
    includeConnectivity: mode == "turn_start"
)

if codexHook {
    try printJSON(codexHookOutput(mode: mode, snapshot: snapshot, stopHookActive: stopHookActive))
} else if outputJSON {
    try printJSON(snapshot.jsonObject(), pretty: true)
} else {
    print(renderText(snapshot))
}

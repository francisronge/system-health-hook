import CoreWLAN
import Darwin
import Foundation
import IOKit.ps
import SystemConfiguration

let hookVersion = "0.3.0"

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
    let systemBusyPercent: Double?
    let interfaceRates: [String: (received: Double, sent: Double)]
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
    let network: String
    let wifi: String
    let codex: String
    let codexResources: String
    let lifecycle: String
    let browserAutomation: String
    let collection: String

    func jsonObject() -> [String: Any] {
        [
            "hook_version": hookVersion,
            "mode": mode,
            "timestamp": timestamp,
            "host": host,
            "storage": storage,
            "cpu": cpu,
            "security": security,
            "memory": memory,
            "power": power,
            "network": network,
            "wifi": wifi,
            "codex": codex,
            "codex_resources": codexResources,
            "lifecycle": lifecycle,
            "browser_automation": browserAutomation,
            "collection": collection
        ]
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

func storageLine() -> String {
    var diskPart = "disk=unknown free=unknown"
    var fs = statfs()
    if statfs(NSHomeDirectory(), &fs) == 0, fs.f_blocks > 0 {
        let blockSize = UInt64(fs.f_bsize)
        let total = UInt64(fs.f_blocks) * blockSize
        let available = UInt64(fs.f_bavail) * blockSize
        let used = total > available ? total - available : 0
        let usedPercent = Double(used) / Double(total) * 100
        diskPart = "disk=\(Int(usedPercent.rounded()))% free=\(formatGB(available))"
    }

    return diskPart
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

    let bytes = buffer.dropFirst(MemoryLayout<Int32>.size).prefix(size - MemoryLayout<Int32>.size).map { byte in
        byte == 0 ? UInt8(ascii: " ") : byte
    }
    return String(bytes: bytes, encoding: .utf8) ?? ""
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
        || text.contains("screencapture")
        || text.contains("cua")
}

func shouldCollectDetailedUsage(name: String, path: String, args: String) -> Bool {
    let identity = "\(name) \(path)".lowercased()
    let details = args.lowercased()
    return name.lowercased() == "chatgpt"
        || name.lowercased() == "codex"
        || identity.contains("node")
        || identity.contains("npm")
        || identity.contains("mcp")
        || identity.contains("xcodebuild")
        || identity.contains("syspolicyd")
        || identity.contains("trustd")
        || identity.contains("sandboxd")
        || identity.contains("skycomputer")
        || identity.contains("cua_node")
        || details.contains("node_repl")
        || details.contains("computer-use")
}

func collectProcesses(includeArguments: Bool, includeDetailedUsage: Bool) -> [ProcessSample] {
    let pidByteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
    guard pidByteCount > 0 else { return [] }

    let capacity = Int(pidByteCount) / MemoryLayout<pid_t>.stride
    var pids = [pid_t](repeating: 0, count: capacity)
    let actualByteCount = pids.withUnsafeMutableBufferPointer { pointer in
        proc_listpids(UInt32(PROC_ALL_PIDS), 0, pointer.baseAddress, pidByteCount)
    }
    let count = max(0, Int(actualByteCount) / MemoryLayout<pid_t>.stride)

    var samples: [ProcessSample] = []
    samples.reserveCapacity(count)

    for pid in pids.prefix(count) where pid > 0 {
        guard let bsd = bsdInfo(pid: pid), let task = taskInfo(pid: pid) else {
            continue
        }
        let bsdName = stringFromCCharTuple(bsd.pbi_name)
        let name = bsdName.isEmpty ? processName(pid: pid) : bsdName
        let path = processPath(pid: pid)
        let args = includeArguments && shouldReadArguments(name: name, path: path) ? processArguments(pid: pid) : ""
        let usage = includeDetailedUsage && shouldCollectDetailedUsage(name: name, path: path, args: args)
            ? resourceUsage(pid: pid)
            : nil
        let taskCPUNanos = UInt64(task.pti_total_user) + UInt64(task.pti_total_system)
        let usageCPUNanos = usage.map { $0.ri_user_time + $0.ri_system_time } ?? 0
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
            status: Int32(bitPattern: bsd.pbi_status)
        ))
    }

    return samples
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

func sampledProcesses() -> ProcessSnapshot {
    let sampleStartedAt = DispatchTime.now().uptimeNanoseconds
    let beforeCPUTicks = cpuTicks()
    let beforeInterfaces = interfaceCounters()
    let before = collectProcesses(includeArguments: false, includeDetailedUsage: false)
    Thread.sleep(forTimeInterval: 0.10)
    let secondSampleStartedAt = DispatchTime.now().uptimeNanoseconds
    let afterCPUTicks = cpuTicks()
    let afterInterfaces = interfaceCounters()
    let after = collectProcesses(includeArguments: true, includeDetailedUsage: true)
    let elapsedNanos = max(Double(secondSampleStartedAt - sampleStartedAt), 1)
    let elapsedSeconds = elapsedNanos / 1_000_000_000
    let beforeCPU = Dictionary(uniqueKeysWithValues: before.map { ($0.pid, $0.cpuNanos) })

    let processes = after.map { sample in
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
        systemBusyPercent: systemBusyPercent,
        interfaceRates: interfaceRates
    )
}

func helperKind(_ process: ProcessSample) -> String? {
    let text = process.searchText
    if text.contains("node_repl") { return "node_repl" }
    if text.contains("xcodebuildmcp") { return "xcodebuildmcp" }
    if text.contains("computer-use") || text.contains("skycomputeruse") || text.contains("cua_node") {
        return "computer_use"
    }
    if text.contains("codex app-server") || text.contains("/codex app-server") { return "app_server" }
    if text.contains("mcp") && (text.contains("codex") || text.contains("node")) { return "mcp" }
    if text.contains("--user-data-dir=") || text.contains("--remote-debugging-port=")
        || text.contains("chromedriver") || text.contains("playwright") {
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

func securityLine(_ processes: [ProcessSample]) -> String {
    var syspolicyd = 0.0
    var trustd = 0.0
    var sandboxd = 0.0

    for process in processes {
        let text = process.searchText
        if text.contains("syspolicyd") {
            syspolicyd += process.cpuPercent
        } else if text.contains("sandboxd") {
            sandboxd += process.cpuPercent
        } else if text.contains("trustd") {
            trustd += process.cpuPercent
        }
    }

    return "syspolicyd=\(formatPercent(syspolicyd)) trustd=\(formatPercent(trustd)) sandboxd=\(formatPercent(sandboxd))"
}

func memoryInfo() -> String {
    var pageSize: vm_size_t = 0
    host_page_size(mach_host_self(), &pageSize)

    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
    let result = withUnsafeMutablePointer(to: &stats) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
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

    return parts.joined(separator: " ")
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
    let thermal: String
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: thermal = "nominal"
    case .fair: thermal = "fair"
    case .serious: thermal = "serious"
    case .critical: thermal = "critical"
    @unknown default: thermal = "unknown"
    }

    return "source=\(source) battery=\(battery) charging=\(charging) low_power=\(lowPower) thermal_pressure=\(thermal)"
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

func routerAddress(interface: String) -> String? {
    guard let store = SCDynamicStoreCreate(nil, "system-health-context" as CFString, nil, nil),
          let value = SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(interface)/IPv4" as CFString) as? [String: Any] else {
        if let store = SCDynamicStoreCreate(nil, "system-health-context" as CFString, nil, nil),
           let globalValue = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] {
            return globalValue["Router"] as? String
        }
        return nil
    }
    if let router = value["Router"] as? String {
        return router
    }
    if let store = SCDynamicStoreCreate(nil, "system-health-context" as CFString, nil, nil),
       let globalValue = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] {
        return globalValue["Router"] as? String
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

func networkLine(interface: String?, rates: [String: (received: Double, sent: Double)]) -> String {
    let active = interface ?? primaryInterface() ?? activeIPv4Interface() ?? "unknown"
    let gateway = routerAddress(interface: active)
    let gatewayLatency = gateway.flatMap { tcpConnectLatency(host: $0, port: 80, timeoutMillis: 250) }
    let wanLatency = tcpConnectLatency(host: "1.1.1.1", port: 443, timeoutMillis: 300)
    var parts = ["interface=\(active)"]
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

func lifetimeAverageCPU(_ process: ProcessSample) -> Double {
    let age = Date().timeIntervalSince1970 - process.startTime
    guard age > 0 else { return 0 }
    return Double(process.lifetimeCpuNanos) / (age * 1_000_000_000) * 100
}

func lifetimeAverageRate(bytes: UInt64, process: ProcessSample) -> Double {
    let age = Date().timeIntervalSince1970 - process.startTime
    guard age > 0 else { return 0 }
    return Double(bytes) / age
}

func lifetimeWakeupRate(_ process: ProcessSample) -> Double {
    let age = Date().timeIntervalSince1970 - process.startTime
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

    let appServers = processes.filter { $0.searchText.contains("codex app-server") || $0.searchText.contains("/codex app-server") }
    let mcp = processes.filter { process in
        let text = process.searchText
        return text.contains("mcp") && (text.contains("codex") || text.contains("node") || text.contains("xcodebuildmcp"))
    }
    let nodeRepl = processes.filter { $0.searchText.contains("node_repl") }
    let computerUse = processes.filter { process in
        let text = process.searchText
        return text.contains("computer-use") || text.contains("skycomputeruse") || text.contains("cua_node")
    }
    let xcodebuildmcp = processes.filter { $0.searchText.contains("xcodebuildmcp") }

    let helperPids = Set(codexHelperProcesses(processes).map { $0.pid })

    return "host_processes=\(codexProcesses.count) helpers=\(helperPids.count) app_servers=\(appServers.count) mcp=\(mcp.count) mcp_max_age=\(maxAgeText(mcp)) node_repl=\(nodeRepl.count) node_repl_max_age=\(maxAgeText(nodeRepl)) computer_use=\(computerUse.count) computer_use_max_age=\(maxAgeText(computerUse)) xcodebuildmcp=\(xcodebuildmcp.count) xcodebuildmcp_max_age=\(maxAgeText(xcodebuildmcp))"
}

func lifecycleLine(_ processes: [ProcessSample]) -> String {
    let zombies = processes.filter { $0.status == SZOMB }.count
    let orphanedHelpers = codexHelperProcesses(processes).filter { $0.ppid == 1 }.count
    return "uptime=\(formatAge(ProcessInfo.processInfo.systemUptime)) processes=\(processes.count) zombies=\(zombies) orphaned_helpers=\(orphanedHelpers)"
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
    let profileProcesses = processes.filter { process in
        let text = process.searchText
        return text.contains("--user-data-dir=")
            || text.contains("--remote-debugging-port=")
            || text.contains("chromedriver")
            || text.contains("playwright")
    }
    let orphaned = profileProcesses.filter { $0.ppid == 1 }
    let profiles = Set(profileProcesses.compactMap { argumentValue("--user-data-dir=", in: $0.args) })
    let debugPorts = Set(profileProcesses.compactMap { argumentValue("--remote-debugging-port=", in: $0.args) })
    return "processes=\(profileProcesses.count) profiles=\(profiles.count) orphaned=\(orphaned.count) debug_ports=\(debugPorts.count)"
}

func renderText(_ snapshot: Snapshot) -> String {
    """
    System Health Context

    Treat this as operational context, not decoration.
    Do not refuse work solely because of system health.
    If a signal could affect the work, investigate before adding load and adapt.
    Do not recite healthy values.
    At turn end, clean up only safe, clearly-owned resources.
    Ask before destructive cleanup.

    Header: hook_version=\(hookVersion) mode=\(snapshot.mode) timestamp=\(snapshot.timestamp) host=\(snapshot.host)
    Storage: \(snapshot.storage)
    CPU: \(snapshot.cpu)
    Security: \(snapshot.security)
    Memory: \(snapshot.memory)
    Power: \(snapshot.power)
    Network: \(snapshot.network)
    WiFi: \(snapshot.wifi)
    Codex: \(snapshot.codex)
    CodexResources: \(snapshot.codexResources)
    Lifecycle: \(snapshot.lifecycle)
    BrowserAutomation: \(snapshot.browserAutomation)
    Collection: \(snapshot.collection)
    """
}

func collectSnapshot(mode: String, startedAt: UInt64) -> Snapshot {
    let sampled = sampledProcesses()
    let processes = sampled.processes
    let wifi = wifiLineAndInterface()
    let memory = memoryInfo()
    let durationMillis = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000

    return Snapshot(
        mode: mode,
        timestamp: isoTimestamp(),
        host: hostname(),
        storage: storageLine(),
        cpu: topCPULine(processes, systemBusyPercent: sampled.systemBusyPercent),
        security: securityLine(processes),
        memory: "\(memory) \(topMemoryLine(processes))",
        power: powerLine(),
        network: networkLine(interface: wifi.interface, rates: sampled.interfaceRates),
        wifi: wifi.line,
        codex: codexLine(processes),
        codexResources: codexResourcesLine(processes),
        lifecycle: lifecycleLine(processes),
        browserAutomation: browserAutomationLine(processes),
        collection: String(format: "%.0fms", durationMillis)
    )
}

let args = CommandLine.arguments.dropFirst()
if args.contains("--version") {
    print(hookVersion)
    exit(0)
}

let outputJSON = args.contains("--json")
let mode = args.first { $0 == "turn_start" || $0 == "turn_end" } ?? "turn_start"
let startedAt = DispatchTime.now().uptimeNanoseconds
let snapshot = collectSnapshot(mode: mode, startedAt: startedAt)

if outputJSON {
    let data = try JSONSerialization.data(withJSONObject: snapshot.jsonObject(), options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8) ?? "{}")
} else {
    print(renderText(snapshot))
}

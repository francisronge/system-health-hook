import CoreWLAN
import Darwin
import Foundation
import IOKit.ps
import SystemConfiguration

let hookVersion = "0.2.0"

struct SizeResult {
    let bytes: UInt64
    let complete: Bool
}

struct ProcessSample {
    let pid: pid_t
    let ppid: pid_t
    let name: String
    let path: String
    let args: String
    let residentBytes: UInt64
    let cpuNanos: UInt64
    let startTime: TimeInterval
    let status: Int32
    var cpuPercent: Double = 0

    var searchText: String {
        "\(name) \(path) \(args)".lowercased()
    }
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

func formatBytesForWorkspace(_ result: SizeResult?) -> String {
    guard let result else { return "unknown" }
    if !result.complete && result.bytes == 0 {
        return "unknown"
    }
    let prefix = result.complete ? "" : ">"
    if result.bytes >= 1_000_000_000 {
        return prefix + formatGB(result.bytes)
    }
    return prefix + formatMB(result.bytes)
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

func boundedDirectorySize(_ url: URL, maxEntries: Int = 2_000, maxMillis: UInt64 = 25) -> SizeResult? {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        return nil
    }

    let start = DispatchTime.now().uptimeNanoseconds
    let deadline = start + maxMillis * 1_000_000
    let keys: [URLResourceKey] = [.isRegularFileKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey]
    guard let enumerator = FileManager.default.enumerator(
        at: url,
        includingPropertiesForKeys: keys,
        options: [.skipsPackageDescendants],
        errorHandler: nil
    ) else {
        return nil
    }

    var bytes: UInt64 = 0
    var count = 0
    for case let fileURL as URL in enumerator {
        count += 1
        if count > maxEntries || DispatchTime.now().uptimeNanoseconds > deadline {
            return SizeResult(bytes: bytes, complete: false)
        }
        if let values = try? fileURL.resourceValues(forKeys: Set(keys)),
           values.isRegularFile == true {
            let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0
            bytes += UInt64(max(size, 0))
        }
    }
    return SizeResult(bytes: bytes, complete: true)
}

func storageLine() -> String {
    let workspaceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

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

    let workspace = formatBytesForWorkspace(boundedDirectorySize(workspaceURL))
    return workspace == "unknown" ? diskPart : "\(diskPart) workspace=\(workspace)"
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

func collectProcesses(includeArguments: Bool) -> [ProcessSample] {
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
        let cpuNanos = UInt64(task.pti_total_user) + UInt64(task.pti_total_system)
        samples.append(ProcessSample(
            pid: pid,
            ppid: pid_t(bitPattern: bsd.pbi_ppid),
            name: name,
            path: path,
            args: args,
            residentBytes: UInt64(task.pti_resident_size),
            cpuNanos: cpuNanos,
            startTime: TimeInterval(bsd.pbi_start_tvsec),
            status: Int32(bitPattern: bsd.pbi_status)
        ))
    }

    return samples
}

func sampledProcesses() -> [ProcessSample] {
    let before = collectProcesses(includeArguments: false)
    let start = DispatchTime.now().uptimeNanoseconds
    Thread.sleep(forTimeInterval: 0.12)
    let afterTime = DispatchTime.now().uptimeNanoseconds
    let after = collectProcesses(includeArguments: true)
    let elapsed = max(Double(afterTime - start), 1)
    let beforeCPU = Dictionary(uniqueKeysWithValues: before.map { ($0.pid, $0.cpuNanos) })

    return after.map { sample in
        var updated = sample
        if let previous = beforeCPU[sample.pid], sample.cpuNanos >= previous {
            updated.cpuPercent = Double(sample.cpuNanos - previous) / elapsed * 100
        }
        return updated
    }
}

func friendlyProcessName(_ process: ProcessSample) -> String {
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

func topCPULine(_ processes: [ProcessSample]) -> String {
    var loads = [Double](repeating: 0, count: 3)
    let loadPart: String
    if getloadavg(&loads, 3) == 3 {
        loadPart = String(format: "load=%.2f/%.2f/%.2f", loads[0], loads[1], loads[2])
    } else {
        loadPart = "load=unknown"
    }

    let top = processes
        .filter { !$0.searchText.contains("system-health-context") }
        .filter { $0.cpuPercent >= 0.05 }
        .sorted { $0.cpuPercent > $1.cpuPercent }
        .prefix(3)
        .map { "\(friendlyProcessName($0)):\(formatPercent($0.cpuPercent))" }
        .joined(separator: ", ")

    return "\(loadPart) top=\(top.isEmpty ? "none" : top)"
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

func memoryInfo() -> (line: String, top: String) {
    var pageSize: vm_size_t = 0
    host_page_size(mach_host_self(), &pageSize)

    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
    let result = withUnsafeMutablePointer(to: &stats) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }

    var freeText = "unknown"
    if result == KERN_SUCCESS {
        let freePages = UInt64(stats.free_count + stats.speculative_count)
        freeText = formatGB(freePages * UInt64(pageSize))
    }

    var parts = ["free=\(freeText)"]
    var swap = xsw_usage()
    var swapSize = MemoryLayout<xsw_usage>.stride
    if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
        parts.append("swap=\(formatGB(UInt64(swap.xsu_used)))")
    }

    let line = parts.joined(separator: " ")
    return (line, "")
}

func topMemoryLine(_ processes: [ProcessSample]) -> String {
    let total = Double(ProcessInfo.processInfo.physicalMemory)
    let top = processes
        .filter { $0.residentBytes > 0 }
        .sorted { $0.residentBytes > $1.residentBytes }
        .prefix(3)
        .map { process in
            let percent = total > 0 ? Double(process.residentBytes) / total * 100 : 0
            return "\(friendlyProcessName(process)):\(formatPercent(percent))"
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

    return "source=\(source) battery=\(battery) charging=\(charging) low_power=\(lowPower) thermal=\(thermal)"
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

func networkLine(interface: String?) -> String {
    let active = interface ?? primaryInterface() ?? activeIPv4Interface() ?? "unknown"
    let gateway = routerAddress(interface: active)
    let gatewayLatency = gateway.flatMap { tcpConnectLatency(host: $0, port: 80, timeoutMillis: 250) }
    let wanLatency = tcpConnectLatency(host: "1.1.1.1", port: 443, timeoutMillis: 300)
    var parts = ["interface=\(active)"]
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

func codexLine(_ processes: [ProcessSample]) -> String {
    let codexProcesses = processes.filter { process in
        let text = process.searchText
        return text.contains("/applications/codex.app") || text.contains(" codex") || text == "codex"
    }

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

    let helperPids = Set((mcp + nodeRepl + computerUse + xcodebuildmcp).map { $0.pid })

    return "processes=\(codexProcesses.count) helpers=\(helperPids.count) app_servers=\(appServers.count) mcp=\(mcp.count) mcp_max_age=\(maxAgeText(mcp)) node_repl=\(nodeRepl.count) node_repl_max_age=\(maxAgeText(nodeRepl)) computer_use=\(computerUse.count) computer_use_max_age=\(maxAgeText(computerUse)) xcodebuildmcp=\(xcodebuildmcp.count) xcodebuildmcp_max_age=\(maxAgeText(xcodebuildmcp))"
}

func lifecycleLine(_ processes: [ProcessSample]) -> String {
    let zombies = processes.filter { $0.status == SZOMB }.count
    return "processes=\(processes.count) zombies=\(zombies)"
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
    let debugPorts = profileProcesses.filter { $0.searchText.contains("--remote-debugging-port=") }
    return "profiles=\(profileProcesses.count) orphaned=\(orphaned.count) debug_ports=\(debugPorts.count)"
}

func renderText(_ snapshot: Snapshot) -> String {
    """
    System Health Context

    Use this as cheap local machine context.
    Do not refuse work solely because of system health.
    If something looks unhealthy, investigate before adding heavier work.
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
    Lifecycle: \(snapshot.lifecycle)
    BrowserAutomation: \(snapshot.browserAutomation)
    Collection: \(snapshot.collection)
    """
}

func collectSnapshot(mode: String, startedAt: UInt64) -> Snapshot {
    let processes = sampledProcesses()
    let wifi = wifiLineAndInterface()
    let memory = memoryInfo()
    let durationMillis = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000

    return Snapshot(
        mode: mode,
        timestamp: isoTimestamp(),
        host: hostname(),
        storage: storageLine(),
        cpu: topCPULine(processes),
        security: securityLine(processes),
        memory: "\(memory.line) \(topMemoryLine(processes))",
        power: powerLine(),
        network: networkLine(interface: wifi.interface),
        wifi: wifi.line,
        codex: codexLine(processes),
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

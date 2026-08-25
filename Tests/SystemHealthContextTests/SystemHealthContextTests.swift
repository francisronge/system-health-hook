import Darwin
import XCTest
@testable import SystemHealthContext

final class SystemHealthContextTests: XCTestCase {
    private func sample(
        pid: pid_t = 42,
        ppid: pid_t = 1,
        name: String = "node",
        path: String = "/usr/local/bin/node",
        args: String = "node",
        age: TimeInterval = 60,
        cpuPercent: Double = 0,
        averageCPU: Double = 0,
        memoryBytes: UInt64 = 80,
        peakMemoryBytes: UInt64 = 120,
        diskWriteBytes: UInt64 = 0,
        idleWakeups: UInt64 = 0,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> ProcessSample {
        var process = ProcessSample(
            pid: pid,
            ppid: ppid,
            name: name,
            path: path,
            args: args,
            residentBytes: memoryBytes,
            physicalFootprintBytes: memoryBytes,
            peakPhysicalFootprintBytes: peakMemoryBytes,
            cpuNanos: 0,
            lifetimeCpuNanos: UInt64(age * averageCPU / 100 * 1_000_000_000),
            diskReadBytes: 0,
            diskWriteBytes: diskWriteBytes,
            idleWakeups: idleWakeups,
            startTime: now - age,
            status: 0
        )
        process.cpuPercent = cpuPercent
        return process
    }

    private func snapshot(
        attention: AttentionAssessment,
        network: String = "",
        wifi: String = ""
    ) -> Snapshot {
        Snapshot(
            mode: "turn_end",
            timestamp: "2026-08-24T00:00:00Z",
            host: "Mac",
            storage: "disk=18% free=1632G",
            cpu: "cores=18 busy=5%",
            security: "syspolicyd=0.0% trustd=0.0% sandboxd=0.0%",
            memory: "pressure=normal ram=68.7G",
            power: "source=AC",
            thermals: "sensor_max=45.0C macos_state=nominal",
            network: network,
            wifi: wifi,
            codex: "helpers=1",
            codexResources: "none",
            lifecycle: "processes=1",
            browserAutomation: "processes=0",
            attention: attention,
            collection: "120ms"
        )
    }

    func testHelperIdentityWinsOverHostApplicationName() {
        let process = sample(
            path: "/Applications/ChatGPT.app/Contents/Resources/node",
            args: "node /tools/node_repl/kernel.js"
        )

        XCTAssertEqual(friendlyProcessName(process), "node_repl")
        XCTAssertEqual(processLabel(process), "node_repl[42]")
    }

    func testMachTicksUseTheHostTimebaseInsteadOfAssumingNanoseconds() {
        XCTAssertEqual(nanosecondsFromMachTicks(24, numerator: 125, denominator: 3), 1_000)
        XCTAssertEqual(nanosecondsFromMachTicks(42, numerator: 1, denominator: 1), 42)
    }

    func testProcessArgumentsStopBeforeEnvironment() {
        var argc: Int32 = 2
        var buffer: [UInt8] = []
        withUnsafeBytes(of: &argc) { buffer.append(contentsOf: $0) }
        buffer.append(contentsOf: Array("/usr/local/bin/node".utf8) + [0, 0])
        buffer.append(contentsOf: Array("node".utf8) + [0])
        buffer.append(contentsOf: Array("script.js".utf8) + [0])
        buffer.append(contentsOf: Array("SECRET_TOKEN=do-not-read".utf8) + [0])

        let arguments = parsedProcessArguments(buffer)
        XCTAssertEqual(arguments, ["node", "script.js"])
        XCTAssertFalse(arguments.joined().contains("SECRET_TOKEN"))
    }

    func testArgumentValueSupportsQuotedAndPlainValues() {
        XCTAssertEqual(argumentValue("--user-data-dir=", in: "chrome --user-data-dir=/tmp/profile --flag"), "/tmp/profile")
        XCTAssertEqual(argumentValue("--user-data-dir=", in: "chrome --user-data-dir=\"/tmp/a profile\" --flag"), "/tmp/a profile")
    }

    func testBrowserAutomationCountsProfilesInsteadOfProcesses() {
        let processes = [
            sample(pid: 1, name: "chrome", args: "chrome --user-data-dir=/tmp/a --remote-debugging-port=9222"),
            sample(pid: 2, name: "chrome", args: "chrome --user-data-dir=/tmp/a --remote-debugging-port=9222"),
            sample(pid: 3, name: "chrome", args: "chrome --user-data-dir=/tmp/b --remote-debugging-port=9333")
        ]

        XCTAssertEqual(
            browserAutomationLine(processes),
            "processes=3 profiles=2 parent_pid_1=3 debug_ports=2"
        )
    }

    func testPhysicalFootprintIsPreferredOverResidentMemory() {
        let process = sample()
        XCTAssertEqual(process.memoryBytes, 80)
        XCTAssertEqual(processMemorySummary(process), "80B/peak=120B")
    }

    func testHelperBucketsAreDisjoint() {
        let processes = [
            sample(pid: 1, args: "node codex-mcp-server"),
            sample(pid: 2, args: "node xcodebuildmcp server"),
            sample(pid: 3, args: "node /tools/node_repl/kernel.js"),
            sample(pid: 4, args: "node computer-use helper"),
            sample(pid: 5, args: "codex app-server")
        ]

        let buckets = helperBuckets(processes)
        XCTAssertEqual(buckets["mcp"]?.map(\.pid), [1])
        XCTAssertEqual(buckets["xcodebuildmcp"]?.map(\.pid), [2])
        XCTAssertEqual(buckets["node_repl"]?.map(\.pid), [3])
        XCTAssertEqual(buckets["computer_use"]?.map(\.pid), [4])
        XCTAssertEqual(buckets["app_server"]?.map(\.pid), [5])
        XCTAssertTrue(shouldCollectDetailedUsage(
            name: "computer_use",
            path: "/tmp/computer_use",
            args: ""
        ))
    }

    func testAppServerCapabilityFlagIsNotComputerUse() {
        let appServer = sample(
            name: "codex",
            path: "/Applications/ChatGPT.app/Contents/Resources/codex",
            args: "codex app-server --enable computer_use"
        )

        XCTAssertEqual(helperKind(appServer), "app_server")
        XCTAssertFalse(containsDelimitedIdentifier("computer_use", in: "computer_usage.js"))
        XCTAssertFalse(containsDelimitedIdentifier("computer-use", in: "computer-user-guide"))
        XCTAssertTrue(containsDelimitedIdentifier("computer_use", in: "node computer_use trusted-worker"))
        XCTAssertFalse(shouldReadArguments(name: "evacuate", path: "/tmp/evacuate"))
    }

    func testDefaultRouteMessageReadsInterfaceIndexAndIPv4Gateway() {
        let headerSize = MemoryLayout<rt_msghdr>.stride
        let addressSize = MemoryLayout<sockaddr_in>.stride
        var header = rt_msghdr()
        header.rtm_msglen = UInt16(headerSize + addressSize)
        header.rtm_version = UInt8(RTM_VERSION)
        header.rtm_index = 7
        header.rtm_addrs = RTA_GATEWAY

        var gateway = sockaddr_in()
        gateway.sin_len = UInt8(addressSize)
        gateway.sin_family = sa_family_t(AF_INET)
        gateway.sin_addr = in_addr(s_addr: inet_addr("10.5.0.1"))

        var bytes: [UInt8] = []
        withUnsafeBytes(of: &header) { bytes.append(contentsOf: $0) }
        withUnsafeBytes(of: &gateway) { bytes.append(contentsOf: $0) }

        let parsed = parsedRouteMessage(bytes)
        XCTAssertEqual(parsed?.interfaceIndex, 7)
        XCTAssertEqual(parsed?.gateway, "10.5.0.1")
    }

    func testLifecycleUsesZombieCountCollectedBeforeTaskLookup() {
        let line = lifecycleLine(
            [sample(ppid: 1, args: "node /tools/node_repl/kernel.js")],
            processCount: 501,
            zombieCount: 3
        )
        XCTAssertTrue(line.contains("processes=501 zombies=3"))
        XCTAssertTrue(line.contains("parent_pid_1_helpers=1"))
    }

    func testBrowserAutomationGetsDetailedResourceUsage() {
        XCTAssertTrue(shouldCollectDetailedUsage(
            name: "chrome-headless-shell",
            path: "/tmp/chrome-headless-shell",
            args: "--user-data-dir=/tmp/profile --remote-debugging-port=9222"
        ))
    }

    func testCodexRendererIsNotBrowserAutomationJustBecauseItHasAUserDataDirectory() {
        let process = sample(
            name: "Codex (Renderer)",
            path: "/Applications/ChatGPT.app/Contents/Frameworks/Codex (Renderer)",
            args: "--type=renderer --user-data-dir=/Users/example/Library/Application Support/Codex"
        )

        XCTAssertFalse(isBrowserAutomationProcess(process))
        XCTAssertNil(helperKind(process))
        XCTAssertTrue(shouldCollectDetailedUsage(
            name: process.name,
            path: process.path,
            args: process.args
        ))
    }

    func testRunawayNodeReplRemainsVisibleOutsideShortCPUSample() {
        let age = 4.5 * 60 * 60
        let process = ProcessSample(
            pid: 5960,
            ppid: 1,
            name: "node",
            path: "/Applications/ChatGPT.app/Contents/Resources/node",
            args: "node /tools/node_repl/kernel.js",
            residentBytes: 11_000_000_000,
            physicalFootprintBytes: 11_000_000_000,
            peakPhysicalFootprintBytes: 40_000_000_000,
            cpuNanos: 0,
            lifetimeCpuNanos: UInt64(age * 1.5 * 1_000_000_000),
            diskReadBytes: 20_000_000_000,
            diskWriteBytes: 2_000_000_000,
            idleWakeups: 100_000,
            startTime: Date().timeIntervalSince1970 - age,
            status: 0
        )

        let line = codexResourcesLine([process])
        XCTAssertTrue(line.contains("cpu=node_repl[5960]:now=0.0%/avg=150%"))
        XCTAssertTrue(line.contains("memory=node_repl[5960]:11.0G/peak=40.0G"))
        XCTAssertTrue(line.contains("read_avg="))
    }

    func testBabelRunawayRequiresAttentionDespiteNominalMacOSThermalState() {
        let now: TimeInterval = 2_000_000_000
        let runaway = sample(
            pid: 35_874,
            ppid: 900,
            name: "ChatGPT",
            path: "/Applications/ChatGPT.app/Contents/Resources/node",
            args: "node computer_use trusted-worker",
            age: 26 * 60 * 60,
            cpuPercent: 132,
            averageCPU: 80,
            memoryBytes: 9_500_000_000,
            peakMemoryBytes: 10_000_000_000,
            now: now
        )
        let thermals = ThermalSnapshot(
            readings: [ThermalReading(group: .die, valueCelsius: 72)],
            fans: [FanReading(currentRPM: 2_000, maximumRPM: 5_800)],
            macOSState: "nominal"
        )

        let assessment = assessAttention(
            storage: StorageStatus(usedPercent: 18, freeBytes: 1_632_000_000_000),
            memory: MemoryStatus(pressure: .normal, detail: "ram=68.7G"),
            security: SecurityStatus(syspolicydCPU: 0, trustdCPU: 0, sandboxdCPU: 0),
            thermals: thermals,
            processes: [runaway],
            now: now
        )

        XCTAssertTrue(assessment.required)
        XCTAssertEqual(assessment.reasons.first?.code, "codex_process_pressure")
        XCTAssertTrue(assessment.reasons.first?.summary.contains("9.5G") == true)
        XCTAssertFalse(assessment.reasons.contains { $0.code == "thermal_pressure" })
    }

    func testOldHelperWithoutResourcePressureDoesNotRequireAttention() {
        let now: TimeInterval = 2_000_000_000
        let healthy = sample(
            ppid: 900,
            args: "node /tools/node_repl/kernel.js",
            age: 34 * 60 * 60,
            cpuPercent: 26,
            averageCPU: 23,
            memoryBytes: 2_100_000_000,
            peakMemoryBytes: 23_800_000_000,
            now: now
        )

        let assessment = assessAttention(
            storage: StorageStatus(usedPercent: 18, freeBytes: 1_632_000_000_000),
            memory: MemoryStatus(pressure: .normal, detail: "ram=68.7G"),
            security: SecurityStatus(syspolicydCPU: 0, trustdCPU: 0, sandboxdCPU: 0),
            thermals: ThermalSnapshot(readings: [], fans: nil, macOSState: "nominal"),
            processes: [healthy],
            now: now
        )

        XCTAssertFalse(assessment.required)
    }

    func testPID1DoesNotCreateAttentionWithoutResourcePressure() {
        let now: TimeInterval = 2_000_000_000
        let launchdOwned = sample(
            ppid: 1,
            args: "node /tools/node_repl/kernel.js",
            age: 34 * 60 * 60,
            cpuPercent: 26,
            averageCPU: 23,
            memoryBytes: 2_100_000_000,
            now: now
        )
        let assessment = assessAttention(
            storage: StorageStatus(usedPercent: 18, freeBytes: 1_632_000_000_000),
            memory: MemoryStatus(pressure: .normal, detail: "ram=68.7G"),
            security: SecurityStatus(syspolicydCPU: 0, trustdCPU: 0, sandboxdCPU: 0),
            thermals: ThermalSnapshot(readings: [], fans: nil, macOSState: "nominal"),
            processes: [launchdOwned],
            now: now
        )

        XCTAssertFalse(assessment.required)
    }

    func testAppServerUsesHostMemoryThreshold() {
        let now: TimeInterval = 2_000_000_000
        let appServer = sample(
            ppid: 1,
            name: "codex",
            path: "/Applications/ChatGPT.app/Contents/Resources/codex",
            args: "codex app-server --enable computer_use",
            age: 2 * 60 * 60,
            memoryBytes: 5_000_000_000,
            now: now
        )
        let assessment = assessAttention(
            storage: StorageStatus(usedPercent: 18, freeBytes: 1_632_000_000_000),
            memory: MemoryStatus(pressure: .normal, detail: "ram=68.7G"),
            security: SecurityStatus(syspolicydCPU: 0, trustdCPU: 0, sandboxdCPU: 0),
            thermals: ThermalSnapshot(readings: [], fans: nil, macOSState: "nominal"),
            processes: [appServer],
            now: now
        )

        XCTAssertFalse(assessment.required)
    }

    func testTransientHostCPUSpikeDoesNotRequireAttention() {
        let now: TimeInterval = 2_000_000_000
        let renderer = sample(
            ppid: 1,
            name: "ChatGPT",
            path: "/Applications/ChatGPT.app/Contents/Frameworks/ChatGPT Helper (Renderer)",
            args: "--type=renderer",
            age: 12 * 60 * 60,
            cpuPercent: 133,
            averageCPU: 2.7,
            memoryBytes: 1_600_000_000,
            now: now
        )
        let assessment = assessAttention(
            storage: StorageStatus(usedPercent: 18, freeBytes: 1_632_000_000_000),
            memory: MemoryStatus(pressure: .normal, detail: "ram=68.7G"),
            security: SecurityStatus(syspolicydCPU: 0, trustdCPU: 0, sandboxdCPU: 0),
            thermals: ThermalSnapshot(readings: [], fans: nil, macOSState: "nominal"),
            processes: [renderer],
            now: now
        )

        XCTAssertFalse(assessment.required)
    }

    func testHotHelperStillRequiresAttentionFromCurrentCPU() {
        let now: TimeInterval = 2_000_000_000
        let helper = sample(
            ppid: 900,
            args: "node computer_use trusted-worker",
            age: 60 * 60,
            cpuPercent: 133,
            averageCPU: 2.7,
            memoryBytes: 1_600_000_000,
            now: now
        )
        let assessment = assessAttention(
            storage: StorageStatus(usedPercent: 18, freeBytes: 1_632_000_000_000),
            memory: MemoryStatus(pressure: .normal, detail: "ram=68.7G"),
            security: SecurityStatus(syspolicydCPU: 0, trustdCPU: 0, sandboxdCPU: 0),
            thermals: ThermalSnapshot(readings: [], fans: nil, macOSState: "nominal"),
            processes: [helper],
            now: now
        )

        XCTAssertEqual(assessment.reasons.map(\.code), ["codex_process_pressure"])
    }

    func testThermalSignalsUseOneAttentionReason() {
        let assessment = assessAttention(
            storage: StorageStatus(usedPercent: 18, freeBytes: 1_632_000_000_000),
            memory: MemoryStatus(pressure: .normal, detail: "ram=68.7G"),
            security: SecurityStatus(syspolicydCPU: 0, trustdCPU: 0, sandboxdCPU: 0),
            thermals: ThermalSnapshot(
                readings: [ThermalReading(group: .cpu, valueCelsius: 101)],
                fans: [FanReading(currentRPM: 5_500, maximumRPM: 5_800)],
                macOSState: "critical"
            ),
            processes: []
        )

        XCTAssertEqual(assessment.reasons.map(\.code), ["thermal_pressure"])
        XCTAssertTrue(assessment.reasons[0].summary.contains("sensor=101.0C"))
        XCTAssertTrue(assessment.reasons[0].summary.contains("macos_state=critical"))
        XCTAssertTrue(assessment.reasons[0].summary.contains("fan=95%_of_max"))
    }

    func testStorageAndSecurityPressureAreDeterministic() {
        let assessment = assessAttention(
            storage: StorageStatus(usedPercent: 97, freeBytes: 30_000_000_000),
            memory: MemoryStatus(pressure: .normal, detail: "ram=16G"),
            security: SecurityStatus(syspolicydCPU: 94, trustdCPU: 0, sandboxdCPU: 0),
            thermals: ThermalSnapshot(readings: [], fans: nil, macOSState: "nominal"),
            processes: []
        )

        XCTAssertEqual(Set(assessment.reasons.map(\.code)), ["storage_pressure", "security_daemon_cpu"])
    }

    func testSecurityCPUOnlyCountsActualDaemonIdentity() {
        let mentionedByNode = sample(
            pid: 1,
            name: "node",
            path: "/usr/local/bin/node",
            args: "node inspect-syspolicyd.js",
            cpuPercent: 100
        )
        let daemon = sample(
            pid: 2,
            name: "syspolicyd",
            path: "/usr/libexec/syspolicyd",
            args: "",
            cpuPercent: 50
        )

        let status = securityStatus([mentionedByNode, daemon])
        XCTAssertEqual(status.syspolicydCPU, 50)
    }

    func testDirectThermalsAreSeparateFromCoarseMacOSState() {
        let thermals = ThermalSnapshot(
            readings: [
                ThermalReading(group: .die, valueCelsius: 48.25),
                ThermalReading(group: .die, valueCelsius: 52.75)
            ],
            fans: [FanReading(currentRPM: 1_450, maximumRPM: 5_777)],
            macOSState: "nominal"
        )

        XCTAssertTrue(thermals.line.contains("sensor_avg=50.5C"))
        XCTAssertTrue(thermals.line.contains("sensor_max=52.8C"))
        XCTAssertTrue(thermals.line.contains("cpu_sensor_max=unavailable"))
        XCTAssertTrue(thermals.line.contains("macos_state=nominal"))
    }

    func testThermalSensorClassificationAndSMCDecoding() {
        XCTAssertEqual(thermalGroup(for: "GPU MTR Temp Sensor 1"), .gpu)
        XCTAssertEqual(thermalGroup(for: "pACC MTR Temp Sensor 2"), .cpu)
        XCTAssertEqual(thermalGroup(for: "PMGR SOC DIE"), .soc)
        XCTAssertEqual(thermalGroup(for: "PMU tdie3"), .die)
        XCTAssertNil(thermalGroup(for: "Battery"))

        XCTAssertEqual(packSMCKey("TCMz"), 0x54434D7A)
        XCTAssertEqual(unpackSMCType(0x666C7420), "flt")

        let temperatureBits = Float(57.5).bitPattern
        let temperatureBytes = (0..<4).map { UInt8((temperatureBits >> UInt32($0 * 8)) & 0xff) }
        XCTAssertEqual(decodeSMCTemperature(type: "flt", bytes: temperatureBytes), 57.5)
        XCTAssertEqual(decodeSMCTemperature(type: "sp78", bytes: [0x2A, 0x80]), 42.5)
        XCTAssertNil(decodeSMCTemperature(type: "sp78", bytes: [0x04, 0x00]))
        XCTAssertNil(decodeSMCTemperature(type: "flt", bytes: [0, 0, 0]))

        XCTAssertEqual(decodeSMCRPM(type: "fpe2", bytes: [0x16, 0xA8]), 1_450)
        let rpmBits = Float(5_777).bitPattern
        let rpmBytes = (0..<4).map { UInt8((rpmBits >> UInt32($0 * 8)) & 0xff) }
        XCTAssertEqual(decodeSMCRPM(type: "flt", bytes: rpmBytes), 5_777)
        XCTAssertNil(decodeSMCRPM(type: "flt", bytes: [0, 0, 0]))
        XCTAssertNil(decodeSMCRPM(type: "unknown", bytes: [0, 0, 0, 0]))
    }

    func testFanOutputDistinguishesNoneFromUnavailable() {
        let noFans = ThermalSnapshot(readings: [], fans: [], macOSState: "nominal")
        let unavailable = ThermalSnapshot(readings: [], fans: nil, macOSState: "nominal")

        XCTAssertTrue(noFans.line.contains("fans=none"))
        XCTAssertTrue(unavailable.line.contains("fans=unavailable"))
    }

    func testTextOmitsUnavailableConnectivityWithoutBlankLines() {
        let value = snapshot(attention: AttentionAssessment(reasons: []))
        let text = renderText(value)

        XCTAssertFalse(text.contains("\n\n\n"))
        XCTAssertTrue(text.contains("Thermals: \(value.thermals)\nCodex:"))
    }

    func testJSONOmitsUnavailableConnectivity() {
        let object = snapshot(attention: AttentionAssessment(reasons: [])).jsonObject()

        XCTAssertFalse(object.keys.contains("network"))
        XCTAssertFalse(object.keys.contains("wifi"))
    }

    func testTextIncludesAvailableConnectivity() {
        let text = renderText(snapshot(
            attention: AttentionAssessment(reasons: []),
            network: "route=en0",
            wifi: "interface=en0"
        ))

        XCTAssertTrue(text.contains("Thermals: sensor_max=45.0C macos_state=nominal\nNetwork: route=en0\nWiFi: interface=en0\nCodex:"))
    }

    func testStopContinuesOnlyOnceWhenAttentionIsRequired() {
        let assessment = AttentionAssessment(reasons: [
            AttentionReason(code: "memory_pressure", summary: "memory pressure is critical", severity: 100)
        ])
        let snapshot = snapshot(attention: assessment)

        let firstStop = codexHookOutput(mode: "turn_end", snapshot: snapshot, stopHookActive: false)
        let repeatedStop = codexHookOutput(mode: "turn_end", snapshot: snapshot, stopHookActive: true)

        XCTAssertEqual(firstStop["decision"] as? String, "block")
        let reason = firstStop["reason"] as? String
        XCTAssertTrue(reason?.hasPrefix("Continue the current task.") == true)
        XCTAssertTrue(reason?.contains("memory pressure is critical") == true)
        XCTAssertTrue(reason?.contains("Then finish the original request.") == true)
        XCTAssertTrue(reason?.contains("Do not replace the requested result with a system-health report.") == true)
        XCTAssertTrue(repeatedStop.isEmpty)
        XCTAssertEqual(Set(firstStop.keys), ["decision", "reason"])
    }

    func testStopHookActiveInputDecoding() {
        XCTAssertTrue(decodeStopHookActive(Data("{\"stop_hook_active\":true}".utf8)))
        XCTAssertFalse(decodeStopHookActive(Data("{\"stop_hook_active\":false}".utf8)))
        XCTAssertFalse(decodeStopHookActive(Data("{}".utf8)))
        XCTAssertFalse(decodeStopHookActive(Data("not json".utf8)))
        XCTAssertFalse(decodeStopHookActive(Data()))
    }

    func testUnknownHealthInputsDoNotInventAttention() {
        let assessment = assessAttention(
            storage: StorageStatus(usedPercent: nil, freeBytes: nil),
            memory: MemoryStatus(pressure: .unknown, detail: "ram=unknown"),
            security: SecurityStatus(syspolicydCPU: 0, trustdCPU: 0, sandboxdCPU: 0),
            thermals: ThermalSnapshot(readings: [], fans: nil, macOSState: "unknown"),
            processes: []
        )

        XCTAssertFalse(assessment.required)
    }

    func testHealthyStopReturnsValidNoOpJSONShape() throws {
        let output = codexHookOutput(
            mode: "turn_end",
            snapshot: snapshot(attention: AttentionAssessment(reasons: []))
        )
        let data = try JSONSerialization.data(withJSONObject: output)

        XCTAssertEqual(String(data: data, encoding: .utf8), "{}")
    }

    func testAttentionReasonsAreCappedAtThree() {
        let now: TimeInterval = 2_000_000_000
        let process = sample(
            ppid: 1,
            args: "node computer-use trusted-worker",
            age: 2 * 60 * 60,
            cpuPercent: 200,
            averageCPU: 100,
            memoryBytes: 9_000_000_000,
            diskWriteBytes: 400_000_000_000,
            now: now
        )
        let assessment = assessAttention(
            storage: StorageStatus(usedPercent: 99, freeBytes: 5_000_000_000),
            memory: MemoryStatus(pressure: .critical, detail: "ram=16G"),
            security: SecurityStatus(syspolicydCPU: 94, trustdCPU: 20, sandboxdCPU: 0),
            thermals: ThermalSnapshot(
                readings: [ThermalReading(group: .die, valueCelsius: 101)],
                fans: [FanReading(currentRPM: 5_500, maximumRPM: 5_800)],
                macOSState: "critical"
            ),
            processes: [process],
            now: now
        )

        XCTAssertEqual(assessment.reasons.count, 3)
    }
}

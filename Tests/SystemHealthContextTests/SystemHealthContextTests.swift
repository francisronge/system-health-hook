import Darwin
import XCTest
@testable import SystemHealthContext

final class SystemHealthContextTests: XCTestCase {
    private func sample(
        pid: pid_t = 42,
        ppid: pid_t = 1,
        name: String = "node",
        path: String = "/usr/local/bin/node",
        args: String = "node"
    ) -> ProcessSample {
        ProcessSample(
            pid: pid,
            ppid: ppid,
            name: name,
            path: path,
            args: args,
            residentBytes: 100,
            physicalFootprintBytes: 80,
            peakPhysicalFootprintBytes: 120,
            cpuNanos: 0,
            lifetimeCpuNanos: 0,
            diskReadBytes: 0,
            diskWriteBytes: 0,
            idleWakeups: 0,
            startTime: Date().timeIntervalSince1970 - 60,
            status: 0
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
            "processes=3 profiles=2 orphaned=3 debug_ports=2"
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
        let line = lifecycleLine([sample(ppid: 2)], processCount: 501, zombieCount: 3)
        XCTAssertTrue(line.contains("processes=501 zombies=3"))
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
}

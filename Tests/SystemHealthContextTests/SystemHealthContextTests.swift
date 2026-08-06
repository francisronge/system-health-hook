import XCTest
@testable import SystemHealthContext

final class SystemHealthContextTests: XCTestCase {
    private func sample(
        pid: pid_t = 42,
        name: String = "node",
        path: String = "/usr/local/bin/node",
        args: String = "node"
    ) -> ProcessSample {
        ProcessSample(
            pid: pid,
            ppid: 1,
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

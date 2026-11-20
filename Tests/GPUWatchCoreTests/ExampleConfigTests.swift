import XCTest
@testable import GPUWatchCore

/// The example files in `examples/` are documentation, and documentation that
/// does not load is worse than none. These tests decode them with the same
/// decoder the app uses, so the README cannot drift away from the real format.
final class ExampleConfigTests: XCTestCase {

    private var examplesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // GPUWatchCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("examples", isDirectory: true)
    }

    private func load(_ name: String) throws -> Data {
        let url = examplesDirectory.appendingPathComponent(name)
        return try Data(contentsOf: url)
    }

    func testExampleConfigurationDecodes() throws {
        let configuration = try ConfigurationStore.decoder
            .decode(AppConfiguration.self, from: load("config.example.json"))

        XCTAssertEqual(configuration.schemaVersion, StoreSchema.currentVersion)
        XCTAssertEqual(configuration.hosts.count, 4)

        let hosts = configuration.hosts
        XCTAssertEqual(hosts[0].destination, "dgx-prod-01")
        XCTAssertNil(hosts[0].username, "an ssh config alias needs no username")
        XCTAssertEqual(hosts[1].port, 2222)
        XCTAssertEqual(hosts[1].username, "ops")
        XCTAssertEqual(hosts[1].identityFile, "~/.ssh/id_ed25519")
        XCTAssertEqual(hosts[1].temperatureWarningThreshold, 80)
        XCTAssertFalse(hosts[2].enabled, "the example shows a disabled host")
        XCTAssertEqual(hosts[3].vendor, .amd, "the example shows an AMD host")
    }

    /// The example carries hosts written before `vendor` existed, so it also
    /// documents that leaving the key out is valid and means auto-detection.
    func testHostsWithoutAVendorKeyMeanAutomaticDetection() throws {
        let configuration = try ConfigurationStore.decoder
            .decode(AppConfiguration.self, from: load("config.example.json"))

        let withoutKey = configuration.hosts.filter { $0.vendor == .auto }
        XCTAssertFalse(withoutKey.isEmpty, "the example must still show a pre-vendor host")
    }

    func testEveryExampleHostPassesValidation() throws {
        let configuration = try ConfigurationStore.decoder
            .decode(AppConfiguration.self, from: load("config.example.json"))
        for host in configuration.hosts {
            XCTAssertNoThrow(
                try SSHTarget.make(from: host),
                "\(host.displayName) should be a usable host"
            )
        }
    }

    func testExampleBaselineDecodes() throws {
        let file = try ConfigurationStore.decoder
            .decode(BaselineFile.self, from: load("baseline.example.json"))

        XCTAssertEqual(file.schemaVersion, StoreSchema.currentVersion)
        let hostID = try XCTUnwrap(
            UUID(uuidString: "4F1C2A70-0E31-4C8B-9A55-8D2E6B1F0A11")
        )
        let baseline = try XCTUnwrap(file.baseline(for: hostID))
        XCTAssertEqual(baseline.gpuUUIDs.count, 8)
        XCTAssertEqual(baseline.expectedCount, 8)
        XCTAssertEqual(baseline.hostID, hostID)
        XCTAssertEqual(Set(baseline.gpuUUIDs).count, 8, "UUIDs must be distinct")
    }

    func testExampleBaselineMatchesTheExampleConfiguration() throws {
        let configuration = try ConfigurationStore.decoder
            .decode(AppConfiguration.self, from: load("config.example.json"))
        let file = try ConfigurationStore.decoder
            .decode(BaselineFile.self, from: load("baseline.example.json"))

        let firstHost = try XCTUnwrap(configuration.hosts.first)
        let baseline = try XCTUnwrap(file.baseline(for: firstHost.id))
        XCTAssertEqual(
            baseline.expectedCount, firstHost.expectedGPUCount,
            "the example baseline and the example host should describe the same machine"
        )
    }

    /// The example must not look like real infrastructure: `.example.` domains
    /// and ssh config aliases only, never a routable address or a credential.
    func testExampleContainsNoRealInfrastructureOrSecrets() throws {
        let text = try String(contentsOf: examplesDirectory
            .appendingPathComponent("config.example.json"), encoding: .utf8)

        XCTAssertFalse(text.contains("PRIVATE KEY"))
        XCTAssertFalse(text.lowercased().contains("password"))
        for reserved in ["192.168.", "10.", "172.16.", "192.0.2."] {
            XCTAssertFalse(text.contains(reserved), "the example must not contain \(reserved)")
        }

        let configuration = try ConfigurationStore.decoder
            .decode(AppConfiguration.self, from: Data(text.utf8))
        for host in configuration.hosts {
            XCTAssertNil(host.identityFile.map { $0.contains("BEGIN") } == true ? host : nil)
            XCTAssertTrue(
                host.destination.hasSuffix(".internal")
                    || host.destination.hasSuffix(".example")
                    || !host.destination.contains(".")
                    || host.destination.hasPrefix("example"),
                "\(host.destination) should not be a real address"
            )
        }
    }
}

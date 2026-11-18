import XCTest
@testable import GPUWatchCore

final class ConfigurationStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try Fixtures.tempDirectory("gpuwatch-store")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> ConfigurationStore {
        ConfigurationStore(directory: directory)
    }

    func testMissingFileIsAFreshInstallNotAnError() {
        let store = makeStore()
        let configuration = store.loadConfiguration()
        XCTAssertTrue(configuration.hosts.isEmpty)
        XCTAssertEqual(configuration.settings.intervalSeconds, PollSettings.defaultInterval)
        XCTAssertTrue(store.currentIssues.isEmpty)
    }

    func testConfigurationRoundTrips() throws {
        let store = makeStore()
        var configuration = AppConfiguration()
        configuration.hosts = [Fixtures.host(port: 2222, temperatureThreshold: 80)]
        configuration.settings.intervalSeconds = 60
        try store.saveConfiguration(configuration)

        let loaded = makeStore().loadConfiguration()
        XCTAssertEqual(loaded.hosts, configuration.hosts)
        XCTAssertEqual(loaded.settings.intervalSeconds, 60)
        XCTAssertEqual(loaded.schemaVersion, StoreSchema.currentVersion)
    }

    func testBaselinesRoundTrip() throws {
        let store = makeStore()
        let host = Fixtures.host()
        var file = BaselineFile()
        file.baselines[host.id.uuidString] = HostBaseline(
            hostID: host.id,
            gpuUUIDs: [Fixtures.uuid(1), Fixtures.uuid(2)],
            expectedCount: 2,
            registeredAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try store.saveBaselines(file)

        let loaded = makeStore().loadBaselines()
        XCTAssertEqual(loaded.baseline(for: host.id)?.gpuUUIDs, [Fixtures.uuid(1), Fixtures.uuid(2)])
        XCTAssertEqual(loaded.baseline(for: host.id)?.expectedCount, 2)
    }

    func testLastKnownRoundTrips() throws {
        let store = makeStore()
        let host = Fixtures.host()
        var file = LastKnownFile()
        file.setSnapshot(HostSnapshot(
            hostID: host.id,
            lastSuccessfulAt: Date(timeIntervalSince1970: 1_700_000_000),
            gpus: [GPUSnapshot(index: 0, uuid: Fixtures.uuid(1), model: "H100", temperatureCelsius: 61)]
        ))
        try store.saveLastKnown(file)

        let loaded = makeStore().loadLastKnown()
        XCTAssertEqual(loaded.snapshot(for: host.id)?.gpus.first?.temperatureCelsius, 61)
    }

    /// The most important behaviour here: a file we cannot read is preserved,
    /// and the operator is told, rather than having their host list replaced by
    /// an empty one.
    func testCorruptConfigurationIsPreservedAndReported() throws {
        let store = makeStore()
        try store.ensureDirectory()
        let original = "{ this is not valid json"
        try original.write(to: store.configurationURL, atomically: true, encoding: .utf8)

        let loaded = store.loadConfiguration()
        XCTAssertTrue(loaded.hosts.isEmpty, "the app starts empty")

        let issues = store.currentIssues
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].kind, .corrupt)
        XCTAssertTrue(issues[0].message.contains("Could not read"))

        // The bytes are still on disk somewhere, unchanged.
        let quarantined = try XCTUnwrap(issues[0].quarantinedTo)
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantined))
        XCTAssertEqual(try String(contentsOfFile: quarantined, encoding: .utf8), original)

        // And the app can go on to write a good file without losing anything.
        try store.saveConfiguration(AppConfiguration(hosts: [Fixtures.host()]))
        XCTAssertEqual(makeStore().loadConfiguration().hosts.count, 1)
    }

    func testNewerSchemaIsRefusedWithoutDataLoss() throws {
        let store = makeStore()
        try store.ensureDirectory()
        let future = """
        { "schemaVersion": 99, "hosts": [], "settings": { "intervalSeconds": 30,
          "maxConcurrentChecks": 5, "notificationsEnabled": false, "launchAtLogin": false } }
        """
        try future.write(to: store.configurationURL, atomically: true, encoding: .utf8)

        let loaded = store.loadConfiguration()
        XCTAssertTrue(loaded.hosts.isEmpty)

        let issue = try XCTUnwrap(store.currentIssues.first)
        XCTAssertEqual(issue.kind, .newerSchema(found: 99, supported: StoreSchema.currentVersion))
        // Refused, not quarantined: a newer file is valid, just unreadable here.
        XCTAssertNil(issue.quarantinedTo)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.configurationURL.path))
    }

    func testWritesAreAtomic() throws {
        let store = makeStore()
        var configuration = AppConfiguration()
        configuration.hosts = (0..<50).map { Fixtures.host(name: "gpu-\($0)", destination: "gpu-\($0).invalid") }
        try store.saveConfiguration(configuration)

        // No stray temporary files left behind in the directory.
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(contents.filter { $0.hasSuffix(".json") }.count, 1)
        XCTAssertTrue(contents.contains("config.json"))
    }

    func testStorageFolderIsPrivate() throws {
        let store = makeStore()
        try store.ensureDirectory()
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue, 0o700, "host names and usernames are not world readable")
    }

    func testDecodingFailureMessagesNameTheField() {
        let json = """
        { "schemaVersion": 1,
          "hosts": [ { "id": "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE",
                       "displayName": "gpu-1", "destination": "gpu-1",
                       "expectedGPUCount": 1, "enabled": true } ],
          "settings": {} }
        """
        do {
            _ = try ConfigurationStore.decoder.decode(AppConfiguration.self, from: data(json))
            XCTFail("expected a decoding failure")
        } catch {
            let message = ConfigurationStore.describeDecodingFailure(error)
            XCTAssertFalse(message.isEmpty)
            XCTAssertTrue(
                message.contains("settings"),
                "the message should point at where it went wrong, got: \(message)"
            )
        }
    }

    func testMalformedUUIDIsReportedReadably() {
        let json = """
        { "schemaVersion": 1,
          "hosts": [ { "id": "not-a-uuid", "displayName": "gpu-1", "destination": "gpu-1",
                       "expectedGPUCount": 1, "enabled": true } ],
          "settings": { "intervalSeconds": 30, "maxConcurrentChecks": 5,
                        "notificationsEnabled": false, "launchAtLogin": false } }
        """
        do {
            _ = try ConfigurationStore.decoder.decode(AppConfiguration.self, from: data(json))
            XCTFail("expected a decoding failure")
        } catch {
            let message = ConfigurationStore.describeDecodingFailure(error)
            XCTAssertTrue(message.contains("hosts"), "got: \(message)")
            XCTAssertTrue(message.contains("[0]"), "the offending index should be named: \(message)")
        }
    }

    private func data(_ json: String) -> Data { Data(json.utf8) }

    func testSettingsAreNormalisedWhenLoadedFromDisk() {
        let store = makeStore()
        var configuration = AppConfiguration()
        configuration.settings.intervalSeconds = 7      // not an allowed value
        configuration.settings.maxConcurrentChecks = 999
        // Bypass the app's own normalisation to simulate a hand-edited file.
        try? store.saveConfiguration(configuration)

        let loaded = store.loadConfiguration()
        XCTAssertEqual(loaded.settings.intervalSeconds, 7, "the store reports what is on disk")

        let normalised = loaded.settings.normalized
        XCTAssertEqual(normalised.intervalSeconds, PollSettings.defaultInterval)
        XCTAssertEqual(normalised.maxConcurrentChecks, PollSettings.maxConcurrencyCeiling)
    }
}

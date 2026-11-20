import XCTest
@testable import GPUWatchCore

/// `vendor` was added after the first release, and Swift's synthesised decoder
/// does not fall back to a property's default value. Without a hand-written
/// decoder, every `config.json` written before the field existed would fail to
/// decode — and an undecodable file is quarantined, which to the operator looks
/// like their host list has been taken away.
///
/// These tests hold that door shut, and also check that the fix did not loosen
/// the fields that were already strict.
final class HostConfigCodingTests: XCTestCase {

    /// A host as it was written by the previous release: every key the type had
    /// then, and no `vendor`.
    private let legacyJSON = """
    {
      "id": "4F1C2A70-0E31-4C8B-9A55-8D2E6B1F0A11",
      "displayName": "5090-1",
      "destination": "5090-1.example.internal",
      "username": "ops",
      "port": 2222,
      "expectedGPUCount": 4,
      "enabled": true
    }
    """

    func testFileWrittenBeforeVendorExistedStillDecodes() throws {
        let host = try ConfigurationStore.decoder
            .decode(HostConfig.self, from: Data(legacyJSON.utf8))

        XCTAssertEqual(host.vendor, .auto, "an existing host is read the way it always was")
        XCTAssertEqual(host.destination, "5090-1.example.internal")
        XCTAssertEqual(host.username, "ops")
        XCTAssertEqual(host.port, 2222)
        XCTAssertEqual(host.expectedGPUCount, 4)
        XCTAssertTrue(host.enabled)
    }

    func testLegacyFileWithNoOptionalFieldsDecodes() throws {
        let json = """
        {
          "id": "7B3D5E91-2A64-4F17-8C0D-1E5A9B7C3D22",
          "displayName": "reserved",
          "destination": "reserved.example.internal",
          "expectedGPUCount": 0,
          "enabled": false
        }
        """
        let host = try ConfigurationStore.decoder
            .decode(HostConfig.self, from: Data(json.utf8))

        XCTAssertEqual(host.vendor, .auto)
        XCTAssertNil(host.username)
        XCTAssertNil(host.identityFile)
        XCTAssertFalse(host.enabled)
    }

    func testVendorSurvivesARoundTrip() throws {
        for vendor in GPUVendor.allCases {
            let host = HostConfig(
                displayName: "amd-1",
                destination: "amd-1.example.internal",
                username: "siamai",
                expectedGPUCount: 4,
                vendor: vendor
            )
            let data = try ConfigurationStore.encoder.encode(host)
            let restored = try ConfigurationStore.decoder.decode(HostConfig.self, from: data)
            XCTAssertEqual(restored, host)
            XCTAssertEqual(restored.vendor, vendor)
        }
    }

    /// Absence means `.auto`. A value we cannot interpret still fails, so a
    /// vendor written by some future build is never silently read as one we do
    /// understand.
    func testUnrecognisedVendorIsRefusedRatherThanGuessed() {
        let json = legacyJSON.replacingOccurrences(
            of: "\"enabled\": true",
            with: "\"enabled\": true, \"vendor\": \"intel\""
        )
        XCTAssertThrowsError(
            try ConfigurationStore.decoder.decode(HostConfig.self, from: Data(json.utf8))
        )
    }

    /// The decoder was written by hand, so the strictness of the fields that
    /// existed before has to be checked separately — it is easy to loosen one
    /// while adding tolerance for another.
    ///
    /// Built from a dictionary rather than by editing the JSON text, so the
    /// only thing removed is the key under test and the failure cannot be a
    /// syntax error in disguise.
    func testFieldsThatWereRequiredAreStillRequired() throws {
        let base = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(legacyJSON.utf8)) as? [String: Any]
        )

        for key in ["id", "displayName", "destination", "expectedGPUCount", "enabled"] {
            var stripped = base
            stripped.removeValue(forKey: key)
            let data = try JSONSerialization.data(withJSONObject: stripped)
            XCTAssertThrowsError(
                try ConfigurationStore.decoder.decode(HostConfig.self, from: data),
                "a file without '\(key)' should still be a decoding failure"
            )
        }
    }
}

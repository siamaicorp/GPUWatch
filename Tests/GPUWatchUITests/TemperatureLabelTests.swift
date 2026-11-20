import XCTest
@testable import GPUWatchUI
@testable import GPUWatchCore

/// A junction reading is hotter than the package sensor for the same card, so
/// showing the number without saying which sensor it came from would let an
/// operator read a threshold against the wrong scale. These pin the wording
/// down, because the AMD host it matters for cannot be reached from a test.
final class TemperatureLabelTests: XCTestCase {

    func testPackageSensorIsNotAnnotated() {
        // The common case stays quiet: nvidia-smi and ROCm's edge sensor both
        // land here, and labelling every ordinary reading would be noise.
        XCTAssertEqual(DS.temperature(58), "58°C")
        XCTAssertEqual(DS.temperature(58, sensor: .core), "58°C")
        XCTAssertNil(GPUTemperatureSensor.core.annotation)
    }

    func testJunctionIsAnnotated() {
        XCTAssertEqual(DS.temperature(50, sensor: .junction), "50°C junction")
        XCTAssertEqual(DS.temperature(48.5, sensor: .junction), "48.5°C junction")
        XCTAssertEqual(GPUTemperatureSensor.junction.annotation, "junction")
    }

    /// An unknown sensor must not become a claim in either direction.
    func testNoSensorIsNotAnnotated() {
        XCTAssertEqual(DS.temperature(50, sensor: nil), "50°C")
    }

    /// Nothing reported is a dash, never a zero — the same rule the rest of the
    /// app follows.
    func testMissingTemperatureIsNotZero() {
        XCTAssertEqual(DS.temperature(nil), "—")
        XCTAssertEqual(DS.temperature(nil, sensor: .junction), "—")
    }
}

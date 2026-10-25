import CoreAudio
import XCTest
@testable import VoicePloeg

@MainActor
final class InputRouteControllerTests: XCTestCase {
    func testRestorationResolvesUIDAfterDeviceIDsChange() throws {
        try withFixture { settings, devices in
            let route = InputRouteController(settings: settings, devices: devices)
            try route.begin(preferred: devices.list[1], available: devices.list)
            XCTAssertEqual(devices.current, 2)
            devices.list[0] = AudioInputDevice(id: 10, name: "Original", transportType: 0, uid: "original")
            // A new controller simulates recovering the saved journal on the next launch.
            try InputRouteController(settings: settings, devices: devices).restore(available: devices.list)
            XCTAssertEqual(devices.current, 10)
            XCTAssertNil(settings.temporaryInputUID)
        }
    }

    func testExternalRouteChangeIsNotOverwritten() throws {
        try withFixture { settings, devices in
            let route = InputRouteController(settings: settings, devices: devices)
            try route.begin(preferred: devices.list[1], available: devices.list)
            devices.current = 3
            try route.restore(available: devices.list)
            XCTAssertEqual(devices.current, 3)
            XCTAssertNil(settings.pendingInputRestorationUID)
        }
    }

    func testFailedSwitchDoesNotLeaveRestorationJournal() throws {
        try withFixture { settings, devices in
            devices.fail = true
            XCTAssertThrowsError(try InputRouteController(settings: settings, devices: devices)
                .begin(preferred: devices.list[1], available: devices.list))
            XCTAssertNil(settings.temporaryInputUID)
        }
    }

    private func withFixture(_ operation: (AppSettings, RouteDevices) throws -> Void) throws {
        let name = "Route-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try operation(AppSettings(userDefaults: defaults), RouteDevices())
    }
}

private final class RouteDevices: AudioInputDeviceManaging {
    var list = [AudioInputDevice(id: 1, name: "Original", transportType: 0, uid: "original"),
        AudioInputDevice(id: 2, name: "Preferred", transportType: 0, uid: "preferred"),
        AudioInputDevice(id: 3, name: "External", transportType: 0, uid: "external")]
    var current: AudioDeviceID = 1
    var fail = false
    func availableInputDevices() -> [AudioInputDevice] { list }
    func defaultInputDeviceID() -> AudioDeviceID? { current }
    func setDefaultInputDeviceID(_ id: AudioDeviceID) throws {
        if fail { throw AudioInputDeviceError.invalidProperty }
        current = id
    }
    func setInputDeviceChangeHandler(_ handler: @escaping @Sendable () -> Void) {}
}

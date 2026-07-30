import CoreAudio
import XCTest
@testable import VoicePloeg

final class AudioInputRecoveryTests: XCTestCase {
    func testKeepsAvailableCurrentDefault() {
        let builtIn = makeDevice(id: 1, name: "MacBook Pro Microphone", transport: kAudioDeviceTransportTypeBuiltIn)

        let result = AudioInputRecovery.fallbackDevice(in: [builtIn], currentDefaultID: builtIn.id)

        XCTAssertNil(result)
    }

    func testSelectsBuiltInDeviceWhenCurrentDefaultIsUnavailable() {
        let external = makeDevice(id: 1, name: "USB Microphone", transport: kAudioDeviceTransportTypeUSB)
        let builtIn = makeDevice(id: 2, name: "MacBook Pro Microphone", transport: kAudioDeviceTransportTypeBuiltIn)

        let result = AudioInputRecovery.fallbackDevice(in: [external, builtIn], currentDefaultID: 99)

        XCTAssertEqual(result, builtIn)
    }

    func testPrefersBuiltInDeviceWhileRecoveringEvenWhenAnotherDefaultIsAvailable() {
        let external = makeDevice(id: 1, name: "USB Microphone", transport: kAudioDeviceTransportTypeUSB)
        let builtIn = makeDevice(id: 2, name: "MacBook Pro Microphone", transport: kAudioDeviceTransportTypeBuiltIn)

        let result = AudioInputRecovery.fallbackDevice(
            in: [external, builtIn],
            currentDefaultID: external.id,
            prefersBuiltIn: true
        )

        XCTAssertEqual(result, builtIn)
    }

    func testSelectsFirstAvailableDeviceWhenBuiltInIsUnavailable() {
        let external = makeDevice(id: 1, name: "USB Microphone", transport: kAudioDeviceTransportTypeUSB)

        let result = AudioInputRecovery.fallbackDevice(in: [external], currentDefaultID: nil)

        XCTAssertEqual(result, external)
    }

    func testReturnsNilWhenNoInputDevicesAreAvailable() {
        let result = AudioInputRecovery.fallbackDevice(in: [], currentDefaultID: nil)

        XCTAssertNil(result)
    }

    private func makeDevice(id: AudioDeviceID, name: String, transport: UInt32) -> AudioInputDevice {
        AudioInputDevice(id: id, name: name, transportType: transport)
    }
}

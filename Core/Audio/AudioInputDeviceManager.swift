import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
    let transportType: UInt32

    var isBluetooth: Bool {
        transportType == kAudioDeviceTransportTypeBluetooth || transportType == kAudioDeviceTransportTypeBluetoothLE
    }

    var isBuiltIn: Bool {
        transportType == kAudioDeviceTransportTypeBuiltIn
    }
}

enum AudioInputDeviceError: Error, LocalizedError {
    case coreAudioError(OSStatus, String)
    case invalidProperty

    var errorDescription: String? {
        switch self {
        case let .coreAudioError(status, operation):
            return "CoreAudio error (\(status)) while \(operation)"
        case .invalidProperty:
            return "Invalid CoreAudio property access"
        }
    }
}

protocol AudioInputDeviceManaging {
    func availableInputDevices() -> [AudioInputDevice]
    func defaultInputDeviceID() -> AudioDeviceID?
    func setDefaultInputDeviceID(_ id: AudioDeviceID) throws
    func setInputDeviceChangeHandler(_ handler: @escaping @Sendable () -> Void)
}

enum AudioInputRecovery {
    static func fallbackDevice(
        in devices: [AudioInputDevice],
        currentDefaultID: AudioDeviceID?,
        prefersBuiltIn: Bool = false
    ) -> AudioInputDevice? {
        if prefersBuiltIn, let builtIn = devices.first(where: \.isBuiltIn) {
            return builtIn.id == currentDefaultID ? nil : builtIn
        }

        if let currentDefaultID, devices.contains(where: { $0.id == currentDefaultID }) {
            return nil
        }

        return devices.first(where: \.isBuiltIn) ?? devices.first
    }
}

final class AudioInputDeviceManager: AudioInputDeviceManaging, @unchecked Sendable {
    private let handlerLock = NSLock()
    private var inputDeviceChangeHandler: (@Sendable () -> Void)?
    private var deviceListListener: AudioObjectPropertyListenerBlock?
    private var defaultInputListener: AudioObjectPropertyListenerBlock?

    init() {
        installInputDeviceListeners()
    }

    deinit {
        removeInputDeviceListeners()
    }

    func availableInputDevices() -> [AudioInputDevice] {
        guard let deviceIDs = try? allDeviceIDs() else {
            return []
        }

        var devices: [AudioInputDevice] = []
        for deviceID in deviceIDs {
            guard hasInputChannels(deviceID) else { continue }
            let name = deviceName(deviceID) ?? "Audio Device \(deviceID)"
            let transportType = deviceTransportType(deviceID) ?? 0
            devices.append(AudioInputDevice(id: deviceID, name: name, transportType: transportType))
        }

        return devices.sorted { lhs, rhs in
            if lhs.isBuiltIn != rhs.isBuiltIn {
                return lhs.isBuiltIn
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(AudioObjectID(kAudioObjectSystemObject), &address) else {
            return nil
        }

        var deviceID = AudioDeviceID(0)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        guard status == noErr else {
            return nil
        }

        return deviceID
    }

    func setDefaultInputDeviceID(_ id: AudioDeviceID) throws {
        var mutableID = id
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(AudioObjectID(kAudioObjectSystemObject), &address) else {
            throw AudioInputDeviceError.invalidProperty
        }

        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &mutableID
        )

        guard status == noErr else {
            throw AudioInputDeviceError.coreAudioError(status, "setting default input device")
        }
    }

    func setInputDeviceChangeHandler(_ handler: @escaping @Sendable () -> Void) {
        handlerLock.withLock {
            inputDeviceChangeHandler = handler
        }
    }

    private func installInputDeviceListeners() {
        var devicesAddress = Self.devicesPropertyAddress
        let deviceListListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.notifyInputDevicesChanged()
        }
        let devicesStatus = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            DispatchQueue.main,
            deviceListListener
        )
        if devicesStatus == noErr {
            self.deviceListListener = deviceListListener
        }

        var defaultInputAddress = Self.defaultInputPropertyAddress
        let defaultInputListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.notifyInputDevicesChanged()
        }
        let defaultStatus = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultInputAddress,
            DispatchQueue.main,
            defaultInputListener
        )
        if defaultStatus == noErr {
            self.defaultInputListener = defaultInputListener
        }
    }

    private func removeInputDeviceListeners() {
        if let deviceListListener {
            var address = Self.devicesPropertyAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                DispatchQueue.main,
                deviceListListener
            )
        }

        if let defaultInputListener {
            var address = Self.defaultInputPropertyAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                DispatchQueue.main,
                defaultInputListener
            )
        }
    }

    private func notifyInputDevicesChanged() {
        let handler = handlerLock.withLock {
            inputDeviceChangeHandler
        }
        handler?()
    }

    private static var devicesPropertyAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static var defaultInputPropertyAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func allDeviceIDs() throws -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(AudioObjectID(kAudioObjectSystemObject), &address) else {
            throw AudioInputDeviceError.invalidProperty
        }

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )
        guard status == noErr else {
            throw AudioInputDeviceError.coreAudioError(status, "getting audio hardware device list size")
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)

        status = deviceIDs.withUnsafeMutableBytes { rawBuffer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize,
                rawBuffer.baseAddress!
            )
        }

        guard status == noErr else {
            throw AudioInputDeviceError.coreAudioError(status, "getting audio hardware device list")
        }

        return deviceIDs
    }

    private func hasInputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard sizeStatus == noErr, dataSize > 0 else {
            return false
        }

        let rawBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawBuffer.deallocate() }

        let bufferList = rawBuffer.assumingMemoryBound(to: AudioBufferList.self)

        var mutableSize = dataSize
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &mutableSize, bufferList)
        guard status == noErr else {
            return false
        }

        let bufferListPointer = UnsafeMutableAudioBufferListPointer(bufferList)
        return bufferListPointer.contains { $0.mNumberChannels > 0 }
    }

    private func deviceName(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var name: CFString?
        var dataSize = UInt32(MemoryLayout<CFString?>.size)

        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, pointer)
        }
        guard status == noErr else {
            return nil
        }

        return name as String?
    }

    private func deviceTransportType(_ deviceID: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var transportType: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &transportType)
        guard status == noErr else {
            return nil
        }

        return transportType
    }
}

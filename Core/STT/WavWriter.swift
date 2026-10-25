import Foundation

enum WavWriter {
    private static let riff = Data([0x52, 0x49, 0x46, 0x46]) // RIFF
    private static let wave = Data([0x57, 0x41, 0x56, 0x45]) // WAVE
    private static let fmt = Data([0x66, 0x6D, 0x74, 0x20]) // fmt<space>
    private static let data = Data([0x64, 0x61, 0x74, 0x61]) // data

    static func write(
        samples: [Float],
        to url: URL,
        sampleRate: Int = 16_000
    ) throws {
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)

        var pcmSamples = [Int16]()
        pcmSamples.reserveCapacity(samples.count)
        for sample in samples {
            let clamped = sample.isFinite ? max(-1.0, min(1.0, sample)) : 0
            let intSample = Int16(clamped * Float(Int16.max))
            pcmSamples.append(intSample.littleEndian)
        }
        let pcmData = pcmSamples.withUnsafeBytes { Data($0) }

        let subchunk2Size = UInt32(pcmData.count)
        let chunkSize = 36 + subchunk2Size

        var data = Data()
        data.append(riff)
        data.append(littleEndianBytes(chunkSize))
        data.append(wave)
        data.append(fmt)
        data.append(littleEndianBytes(UInt32(16)))
        data.append(littleEndianBytes(UInt16(1)))
        data.append(littleEndianBytes(numChannels))
        data.append(littleEndianBytes(UInt32(sampleRate)))
        data.append(littleEndianBytes(byteRate))
        data.append(littleEndianBytes(blockAlign))
        data.append(littleEndianBytes(bitsPerSample))
        data.append(Self.data)
        data.append(littleEndianBytes(subchunk2Size))
        data.append(pcmData)

        try data.write(to: url, options: .atomic)
    }

    private static func littleEndianBytes<T: FixedWidthInteger>(_ value: T) -> Data {
        var littleEndian = value.littleEndian
        return withUnsafeBytes(of: &littleEndian) { Data($0) }
    }
}

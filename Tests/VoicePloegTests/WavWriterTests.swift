import XCTest
@testable import VoicePloeg

final class WavWriterTests: XCTestCase {
    func testWriteProducesWavHeader() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try WavWriter.write(samples: [0.0, 1.0, -1.0], to: tempURL, sampleRate: 16_000)
        let data = try Data(contentsOf: tempURL)

        XCTAssertTrue(data.starts(with: Array("RIFF".utf8)))
        XCTAssertEqual(String(data: data[8..<12], encoding: .ascii), "WAVE")
    }

    func testWriteUsesExpectedDataChunkSize() throws {
        let samples: [Float] = [0.25, -0.25, 0.75, -0.75]
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try WavWriter.write(samples: samples, to: tempURL, sampleRate: 16_000)
        let data = try Data(contentsOf: tempURL)

        var chunkSize: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &chunkSize) { destination in
            data.copyBytes(to: destination, from: 40..<44)
        }
        XCTAssertEqual(Int(UInt32(littleEndian: chunkSize)), samples.count * 2)
    }
}

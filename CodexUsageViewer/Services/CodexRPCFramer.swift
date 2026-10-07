import Foundation

/// Newline-delimited JSON; retain partial bytes to preserve split UTF-8.
struct CodexRPCFramer {
    private var buffer = Data()
    private let maximumLineBytes: Int

    init(maximumLineBytes: Int = 2_097_152) {
        self.maximumLineBytes = maximumLineBytes
    }

    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            guard line.count <= maximumLineBytes else { throw CodexConnectionError.invalidResponse }
            if !line.isEmpty && line != Data([0x0D]) { lines.append(Data(line)) }
            buffer.removeSubrange(...newline)
        }
        guard buffer.count <= maximumLineBytes else { throw CodexConnectionError.invalidResponse }
        return lines
    }
}

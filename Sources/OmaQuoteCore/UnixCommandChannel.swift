import Darwin
import Foundation

public enum CommandChannelError: Error, LocalizedError {
    case pathTooLong
    case alreadyRunning
    case systemCall(String, Int32)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .pathTooLong: "Command socket path is too long"
        case .alreadyRunning: "OmaQuote is already running"
        case .systemCall(let name, let code): "\(name): \(String(cString: strerror(code)))"
        case .invalidResponse: "The OmaQuote command response was invalid"
        }
    }
}

private func socketAddress<R>(for path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> R) throws -> R {
    var address = sockaddr_un()
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
        throw CommandChannelError.pathTooLong
    }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        for (index, byte) in bytes.enumerated() { buffer[index] = byte }
        buffer[bytes.count] = 0
    }
    return try withUnsafePointer(to: &address) { pointer in
        try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            try body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}

private func writeLine(_ text: String, to descriptor: Int32) throws {
    let bytes = Array((text + "\n").utf8)
    try bytes.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
            let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
            if count <= 0 { throw CommandChannelError.systemCall("write", errno) }
            offset += count
        }
    }
}

private func readLine(from descriptor: Int32, limit: Int = 65_536) throws -> String {
    var bytes: [UInt8] = []
    while bytes.count < limit {
        var byte: UInt8 = 0
        let count = Darwin.read(descriptor, &byte, 1)
        if count < 0 { throw CommandChannelError.systemCall("read", errno) }
        if count == 0 { break }
        if byte == 10 { break }
        bytes.append(byte)
    }
    guard let line = String(bytes: bytes, encoding: .utf8), !line.isEmpty else {
        throw CommandChannelError.invalidResponse
    }
    return line
}

public enum UnixCommandClient {
    public static func send(_ command: String, to path: String) throws -> String {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw CommandChannelError.systemCall("socket", errno) }
        defer { Darwin.close(descriptor) }
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let result = try socketAddress(for: path) { address, size in
            Darwin.connect(descriptor, address, size)
        }
        guard result == 0 else { throw CommandChannelError.systemCall("connect", errno) }
        try writeLine(command, to: descriptor)
        return try readLine(from: descriptor)
    }
}

public final class UnixCommandServer: @unchecked Sendable {
    private let descriptor: Int32
    private let path: String
    private let lock = NSLock()
    private var stopped = false

    public init(path: String, handler: @escaping @Sendable (String) -> String) throws {
        self.path = path
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: path) {
            if (try? UnixCommandClient.send("status", to: path)) != nil {
                throw CommandChannelError.alreadyRunning
            }
            Darwin.unlink(path)
        }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw CommandChannelError.systemCall("socket", errno) }
        self.descriptor = descriptor
        do {
            let result = try socketAddress(for: path) { address, size in
                Darwin.bind(descriptor, address, size)
            }
            guard result == 0 else { throw CommandChannelError.systemCall("bind", errno) }
            Darwin.chmod(path, S_IRUSR | S_IWUSR)
            guard Darwin.listen(descriptor, 8) == 0 else {
                throw CommandChannelError.systemCall("listen", errno)
            }
        } catch {
            Darwin.close(descriptor)
            Darwin.unlink(path)
            throw error
        }
        DispatchQueue(label: "omaquote.command-server").async {
            while true {
                let client = Darwin.accept(descriptor, nil, nil)
                if client < 0 { break }
                var noSignal: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                var timeout = timeval(tv_sec: 3, tv_usec: 0)
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                do {
                    let command = try readLine(from: client, limit: 128)
                    try writeLine(handler(command), to: client)
                } catch {
                    try? writeLine("error: \(error.localizedDescription)", to: client)
                }
                Darwin.close(client)
            }
        }
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        stopped = true
        Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
        Darwin.unlink(path)
    }

    deinit { stop() }
}

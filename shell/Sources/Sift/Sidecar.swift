import Foundation

/// Owns the Python engine process.
///
/// Lifecycle rules this type exists to enforce:
///  * The engine binds port 0 and reports the real port on stdout, so nothing hardcodes a port that
///    might already be taken.
///  * The engine's stdin stays connected to us. When this app exits — cleanly, by crash, or by
///    `kill -9` — the pipe closes and the engine's watcher thread exits it. That is what prevents
///    the classic orphaned-process-holding-a-port problem.
final class Sidecar {
    struct Handshake {
        let port: Int
        let token: String
    }

    private let process = Process()
    private let stdout = Pipe()
    private let stdin = Pipe()
    private var buffer = Data()

    let root: URL

    init(root: URL) {
        self.root = root
    }

    /// Start the engine and wait for its one-line JSON handshake.
    func start(timeout: TimeInterval = 25) throws -> Handshake {
        let python = root.appendingPathComponent(".venv/bin/python")
        let entry = root.appendingPathComponent("engine/app.py")

        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw SiftError.setup("""
            No Python environment at \(python.path).

            Sift's engine runs on the repo's own venv. Create it once:
              cd \(root.path)
              uv venv --python 3.12 .venv
              uv pip install --python .venv/bin/python -r requirements.txt
            """)
        }
        guard FileManager.default.fileExists(atPath: entry.path) else {
            throw SiftError.setup("Engine not found at \(entry.path).")
        }

        process.executableURL = python
        process.arguments = [entry.path, "--sidecar"]
        process.currentDirectoryURL = root
        process.standardOutput = stdout
        process.standardInput = stdin
        // Leave stderr attached so engine logs land in Console.app rather than vanishing.
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env

        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        let handle = stdout.fileHandleForReading
        while Date() < deadline {
            if let line = readLine(from: handle) {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let port = obj["port"] as? Int,
                      let token = obj["token"] as? String
                else { continue }   // ignore anything that is not the handshake
                drainInBackground(handle)
                return Handshake(port: port, token: token)
            }
            if !process.isRunning { break }
        }
        throw SiftError.setup("The engine did not start within \(Int(timeout))s.")
    }

    private func readLine(from handle: FileHandle) -> String? {
        while true {
            if let idx = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<idx)
                buffer.removeSubrange(buffer.startIndex...idx)
                return String(data: line, encoding: .utf8)
            }
            let chunk = handle.availableData
            if chunk.isEmpty { return nil }
            buffer.append(chunk)
        }
    }

    /// Keep reading stdout after the handshake, or the engine will eventually block on a full pipe.
    private func drainInBackground(_ handle: FileHandle) {
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                if let s = String(data: chunk, encoding: .utf8), !s.isEmpty {
                    FileHandle.standardError.write(Data(s.utf8))
                }
            }
        }
    }

    func stop() {
        guard process.isRunning else { return }
        // Closing stdin is the polite signal: the engine's watcher sees EOF and exits itself.
        try? stdin.fileHandleForWriting.close()
        process.terminate()
        // Give it a moment, then insist.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { [process] in
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}

enum SiftError: LocalizedError {
    case setup(String)

    var errorDescription: String? {
        switch self {
        case .setup(let msg): return msg
        }
    }
}

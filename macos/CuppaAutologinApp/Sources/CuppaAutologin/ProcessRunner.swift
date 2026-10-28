import Foundation
import Darwin

struct ProcessResult: Sendable {
    let status: Int32
    let output: String
    let error: String
}

enum ProcessRunner {
    @discardableResult
    static func run(
        _ executable: String,
        _ arguments: [String],
        currentDirectory: URL? = nil,
        timeout: TimeInterval = 120
    ) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        var timedOut = false
        do {
            // Anonymous owner-only files cannot fill a pipe and block the child.
            // They also let a timeout return if a descendant inherited stdout.
            let outputFile = try outputHandle()
            let errorFile = try outputHandle()
            defer {
                try? outputFile.close()
                try? errorFile.close()
            }
            process.standardOutput = outputFile
            process.standardError = errorFile
            try process.run()
            let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                timedOut = true
                process.terminate()
                let grace = ProcessInfo.processInfo.systemUptime + 0.5
                while process.isRunning && ProcessInfo.processInfo.systemUptime < grace {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
            try outputFile.seek(toOffset: 0)
            try errorFile.seek(toOffset: 0)
            return ProcessResult(
                status: timedOut ? 124 : process.terminationStatus,
                output: String(decoding: try outputFile.readToEnd() ?? Data(), as: UTF8.self),
                error: timedOut ? "Process timed out" : String(decoding: try errorFile.readToEnd() ?? Data(), as: UTF8.self)
            )
        } catch {
            return ProcessResult(
                status: -1,
                output: "",
                error: error.localizedDescription
            )
        }

    }

    private static func outputHandle() throws -> FileHandle {
        var path = Array(FileManager.default.temporaryDirectory
            .appendingPathComponent("cuppa-process-XXXXXX").path.utf8CString)
        let descriptor = mkstemp(&path)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        // Unlink immediately: no command output is left in a named temp file,
        // including after a crash. The descriptor remains open for the child.
        if unlink(path) != 0 {
            let failure = errno
            close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
}

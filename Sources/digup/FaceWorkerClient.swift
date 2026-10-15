import DigUpKit
import Foundation

/// One local worker per job. It sees prepared images only and has no shell, user PATH lookup or network argument.
final class FaceWorkerClient {
    private let process = Process()
    private let input = Pipe(), output = Pipe()
    private let token: FaceCancellation
    private var buffer = Data(), sequence = 0
    private var launched = false, closed = false
    init(executable: URL, models: URL, device: String, token: FaceCancellation) throws {
        self.token = token
        process.executableURL = executable
        let runtimeName: String
        #if os(Windows)
        runtimeName = "onnxruntime.dll"
        #elseif os(macOS)
        runtimeName = "libonnxruntime.dylib"
        #else
        runtimeName = "libonnxruntime.so"
        #endif
        let runtime = executable.deletingLastPathComponent().appendingPathComponent(runtimeName)
        process.arguments = ["--models", models.path, "--runtime", runtime.path, "--device", device]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try token.launch(process)
        launched = true
        // The first message is an unsolicited startup readiness record. Never mistake it for an analyze response.
        let ready = try read()
        guard ready["ok"] as? Bool != false, ready["error"] == nil else {
            close(); throw CLIError("The face runtime could not start. Check the packaged ONNX Runtime and models.")
        }
    }
    func request(_ fields: [String: Any]) throws -> [String: Any] {
        try token.check()
        sequence += 1
        var request = fields; request["id"] = sequence
        var data = try JSONSerialization.data(withJSONObject: request); data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
        let reply = try read()
        guard (reply["id"] as? NSNumber)?.intValue == sequence, reply["ok"] as? Bool == true else {
            throw CLIError("The face runtime could not analyze this file. Retry after checking the model and runtime.")
        }
        return reply
    }
    private func read() throws -> [String: Any] {
        let process = process
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 180, execute: watchdog)
        defer { watchdog.cancel() }
        while true {
            try token.check()
            if let end = buffer.firstIndex(of: 10) {
                let line = buffer[..<end]; buffer.removeSubrange(...end)
                guard let json = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw CLIError("Invalid face runtime response.") }
                return json
            }
            // readData(ofLength:) waits to fill the requested buffer on Windows pipes. JSONL replies are much
            // shorter than 64 KiB, so use the same availableData pipe primitive as EmbeddingWorker.
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else { try token.check(); throw CLIError("The face runtime stopped unexpectedly. Check its packaged DLLs and retry.") }
            buffer.append(chunk)
            guard buffer.count <= 16 << 20 else { throw CLIError("The face runtime response exceeded its limit.") }
        }
    }
    func close() {
        guard launched, !closed else { return }
        closed = true
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        process.waitUntilExit(); token.forget(process)
        try? output.fileHandleForReading.close()
    }
    deinit { close() }
}

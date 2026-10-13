import DigUpKit
import Foundation

/// The same choice is used by the CLI and the desktop helper. CPU_ONLY remains a release-test override.
public enum LlamaDevice: String, Sendable {
    case auto, cpu, gpu

    public static func resolve(requested: LlamaDevice? = nil,
                               environment: [String: String] = ProcessInfo.processInfo.environment) throws -> LlamaDevice {
        if environment["DIGUP_CPU_ONLY"] == "1" { return .cpu }
        if let requested { return requested }
        let value = environment["DIGUP_DEVICE"] ?? "auto"
        guard let device = LlamaDevice(rawValue: value) else {
            throw WorkerError.failed("DIGUP_DEVICE must be auto, cpu or gpu")
        }
        return device
    }
}

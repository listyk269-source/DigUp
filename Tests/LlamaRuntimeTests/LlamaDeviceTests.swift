import Testing
@testable import LlamaRuntime

@Suite struct LlamaDeviceTests {
    @Test func defaultAndExplicitModes() throws {
        #expect(try LlamaDevice.resolve(environment: [:]) == .auto)
        for device in [LlamaDevice.auto, .cpu, .gpu] {
            #expect(try LlamaDevice.resolve(environment: ["DIGUP_DEVICE": device.rawValue]) == device)
        }
        #expect(try LlamaDevice.resolve(requested: .gpu, environment: ["DIGUP_DEVICE": "cpu"]) == .gpu)
    }

    @Test func cpuOverrideWinsOverEveryPreference() throws {
        #expect(try LlamaDevice.resolve(requested: .gpu, environment: ["DIGUP_CPU_ONLY": "1"]) == .cpu)
        #expect(try LlamaDevice.resolve(environment: ["DIGUP_CPU_ONLY": "1", "DIGUP_DEVICE": "gpu"]) == .cpu)
        #expect(try LlamaDevice.resolve(environment: ["DIGUP_CPU_ONLY": "0", "DIGUP_DEVICE": "gpu"]) == .gpu)
    }

    @Test func invalidEnvironmentIsAnActionableError() {
        #expect(throws: (any Error).self) { try LlamaDevice.resolve(environment: ["DIGUP_DEVICE": "cuda"]) }
        #expect(throws: (any Error).self) { try LlamaDevice.resolve(environment: ["DIGUP_DEVICE": ""]) }
    }
}

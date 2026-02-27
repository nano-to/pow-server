import Foundation
import Metal
import MetalKit
import Crypto
import Network

// Main entry point - using Task to run async code
let mainTask = Task { @MainActor in
    print("🚀 Starting Nano PoW Service on M3 GPU...")
    fflush(stdout)
    
    guard let device = MTLCreateSystemDefaultDevice() else {
        print("❌ Error: Metal is not supported on this device")
        fflush(stdout)
        exit(1)
    }
    
    print("✅ Found GPU: \(device.name)")
    fflush(stdout)
    
    let service = NanoPoWGenerator(device: device)
    
    // Run as a background service
    await service.run()
}

// Keep the process alive and wait for the task
RunLoop.main.run()

class NanoPoWGenerator {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue?
    let library: MTLLibrary?
    let computePipeline: MTLComputePipelineState?
    var gpuBuffers: GPUBuffers?
    var httpServer: LocalPoWServer?
    
    init(device: MTLDevice) {
        self.device = device
        
        // Initialize Metal components (optional for now)
        self.commandQueue = device.makeCommandQueue()
        
        // Try to load Metal shader library
        var library: MTLLibrary?
        var function: MTLFunction?
        
        // Try Bundle.module first (source-based compilation)
        if let lib = try? device.makeDefaultLibrary(bundle: Bundle.module) {
            library = lib
            function = lib.makeFunction(name: "blake2b_pow")
            if function != nil {
                print("   Found shader in Bundle.module")
            }
        }
        
        // Try loading from compiled metallib in bundle
        if function == nil, let metallibPath = Bundle.module.path(forResource: "Default", ofType: "metallib"),
           let lib = try? device.makeLibrary(filepath: metallibPath) {
            library = lib
            function = lib.makeFunction(name: "blake2b_pow")
            if function != nil {
                print("   Found shader in compiled metallib")
            }
        }
        
        // Fallback to default library
        if function == nil {
            if let lib = device.makeDefaultLibrary() {
                library = lib
                function = lib.makeFunction(name: "blake2b_pow")
            }
        }
        
        if let lib = library, let shaderFunc = function {
            do {
                let pipeline = try device.makeComputePipelineState(function: shaderFunc)
                self.library = lib
                self.computePipeline = pipeline
                print("✅ Metal GPU acceleration ready")
                print("   Pipeline thread execution width: \(pipeline.threadExecutionWidth)")
            } catch {
                self.library = nil
                self.computePipeline = nil
                print("⚠️  Metal pipeline creation failed: \(error)")
                print("   Using CPU acceleration")
            }
        } else {
            self.library = nil
            self.computePipeline = nil
            if function == nil {
                print("⚠️  Metal shader function 'blake2b_pow' not found")
                if library == nil {
                    print("   Library also not found")
                }
            }
            print("   Using CPU acceleration")
        }
    }

    struct GPUBuffers {
        let batchSize: Int
        let hashBuffer: MTLBuffer
        let validIndicesBuffer: MTLBuffer
        let validCountBuffer: MTLBuffer
    }
    
    func run() async {
        print("📡 Service running. Waiting for work requests...")
        fflush(stdout)
        print("💡 To test, send a POST request with block hash to generate PoW")
        fflush(stdout)
        
        selfTestBlake2b()
        await selfTestGPUHash()
        
        if CommandLine.arguments.contains("--gpu-self-test") {
            print("✅ GPU self-test complete, exiting.")
            fflush(stdout)
            return
        }

        let server = LocalPoWServer(generator: self, port: resolvePort())
        server.start()
        httpServer = server
        print("🌐 Local PoW server listening at http://127.0.0.1:\(server.portString)")
        fflush(stdout)
        
        // Keep service running
        print("🔄 Service is running. Press Ctrl+C to stop.")
        // Use Task.sleep in a loop to keep service alive
        while true {
            try? await Task.sleep(nanoseconds: 1_000_000_000) // Sleep 1 second
        }
    }
    
    func generateWork(for blockHash: String) async -> String? {
        guard let hashData = Data(hexString: blockHash) else {
            print("❌ Invalid block hash format")
            return nil
        }
        
        print("⛏️  Mining PoW on GPU...")
        fflush(stdout)
        let startTime = Date()
        
        // Nano PoW: Find a 64-bit work value such that Blake2b(work || block_hash) meets difficulty
        let threshold: UInt64 = 0xfffffff93c41ec94
        print("🔧 Using difficulty threshold: \(String(format: "%016llX", threshold))")
        fflush(stdout)
        
        var work: UInt64 = 0
        var found = false
        var batchIndex: UInt64 = 0
        
        // Use GPU for parallel computation - moderate batches for GPU
        // For CPU, use aggressive parallelization
        let batchSize: UInt64 = computePipeline != nil ? 2_000_000 : 1_000_000
        
        while !found && work < UInt64.max - batchSize {
            batchIndex += 1
            print("🚧 Batch \(batchIndex) startWork=\(work)")
            fflush(stdout)
            if let result = await computeBatch(startWork: work, blockHash: hashData, batchSize: batchSize, threshold: threshold) {
                work = result
                found = true
                print("✅ Batch \(batchIndex) found work")
                fflush(stdout)
            } else {
                work += batchSize
                print("❌ Batch \(batchIndex) no work")
                fflush(stdout)
            }
            
            // Progress indicator - print every 1M attempts
            if work > 0 && work % 1_000_000 == 0 {
                let elapsed = Date().timeIntervalSince(startTime)
                if elapsed > 0 {
                    let rate = Double(work) / elapsed
                    print("  ⏳ \(work / 1_000_000)M attempts, \(String(format: "%.1f", rate / 1_000_000))M hashes/sec, elapsed: \(String(format: "%.1f", elapsed))s")
                    fflush(stdout)
                }
            }
            
            // Also print every 10M for longer runs
            if work > 0 && work % 10_000_000 == 0 {
                let elapsed = Date().timeIntervalSince(startTime)
                let rate = Double(work) / elapsed
                print("  📊 \(work / 1_000_000)M attempts, \(String(format: "%.2f", rate / 1_000_000))M hashes/sec")
                fflush(stdout)
            }
        }
        
        if found {
            let elapsed = Date().timeIntervalSince(startTime)
            print("✅ Found valid work in \(String(format: "%.2f", elapsed))s")
            fflush(stdout)
            return String(format: "%016llX", work)
        }
        
        return nil
    }
    
    func computeBatch(startWork: UInt64, blockHash: Data, batchSize: UInt64, threshold: UInt64) async -> UInt64? {
        // Use GPU acceleration if available
        if let pipeline = computePipeline, let commandQueue = commandQueue {
            return await computeBatchGPU(startWork: startWork, blockHash: blockHash, batchSize: batchSize, threshold: threshold, pipeline: pipeline, commandQueue: commandQueue)
        }
        
        // Fallback to CPU with parallel processing
        return await withTaskGroup(of: UInt64?.self) { group in
            // Use more parallel chunks for CPU - utilize all cores
            let numCores = ProcessInfo.processInfo.processorCount
            let chunkSize: UInt64 = max(10_000, batchSize / UInt64(numCores * 4)) // More chunks for better parallelization
            let numChunks = (batchSize + chunkSize - 1) / chunkSize
            
            for chunk in 0..<numChunks {
                let chunkStart = startWork + (UInt64(chunk) * chunkSize)
                let chunkEnd = min(chunkStart + chunkSize, startWork + batchSize)
                
                group.addTask {
                    return await self.computeChunk(
                        startWork: chunkStart,
                        endWork: chunkEnd,
                        blockHash: blockHash,
                        threshold: threshold
                    )
                }
            }
            
            // Return first found result
            for await result in group {
                if let work = result {
                    group.cancelAll()
                    return work
                }
            }
            
            return nil
        }
    }
    
    func computeBatchGPU(startWork: UInt64, blockHash: Data, batchSize: UInt64, threshold: UInt64, pipeline: MTLComputePipelineState, commandQueue: MTLCommandQueue) async -> UInt64? {
        let device = commandQueue.device
        guard let localQueue = device.makeCommandQueue() else { return nil }
        
        let count = Int(batchSize)
        let batchStartTime = Date()
        
        // Create or reuse buffers
        if gpuBuffers == nil || gpuBuffers?.batchSize != count {
            guard let validIndicesBuffer = device.makeBuffer(length: 1024 * MemoryLayout<UInt32>.size, options: .storageModeShared),
                  let validCountBuffer = device.makeBuffer(length: MemoryLayout<UInt32>.size, options: .storageModeShared),
                  let hashBuffer = device.makeBuffer(length: count * MemoryLayout<UInt64>.size, options: .storageModeShared) else {
                return nil
            }
            gpuBuffers = GPUBuffers(batchSize: count, hashBuffer: hashBuffer, validIndicesBuffer: validIndicesBuffer, validCountBuffer: validCountBuffer)
        }
        guard let buffers = gpuBuffers else { return nil }
        
        // Initialize valid count to 0
        buffers.validCountBuffer.contents().bindMemory(to: UInt32.self, capacity: 1).pointee = 0
        
        // Create command buffer
        guard let commandBuffer = localQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }
        
        encoder.setComputePipelineState(pipeline)
        encoder.setBytes([startWork], length: MemoryLayout<UInt64>.size, index: 0)
        encoder.setBytes(Array(blockHash), length: blockHash.count, index: 1)
        encoder.setBuffer(buffers.hashBuffer, offset: 0, index: 2)
        encoder.setBuffer(buffers.validIndicesBuffer, offset: 0, index: 3)
        encoder.setBuffer(buffers.validCountBuffer, offset: 0, index: 4)
        encoder.setBytes([UInt32(count)], length: MemoryLayout<UInt32>.size, index: 5)
        encoder.setBytes([threshold], length: MemoryLayout<UInt64>.size, index: 6)
        
        // Calculate threadgroup size
        let threadgroupSize = MTLSize(width: pipeline.threadExecutionWidth, height: 1, depth: 1)
        let threadgroupCount = MTLSize(width: (count + threadgroupSize.width - 1) / threadgroupSize.width, height: 1, depth: 1)
        
        encoder.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()
        
        let completionGroup = DispatchGroup()
        completionGroup.enter()
        commandBuffer.addCompletedHandler { _ in
            completionGroup.leave()
        }
        commandBuffer.commit()
        
        let waitResult = completionGroup.wait(timeout: .now() + 0.5)
        if waitResult == .timedOut {
            print("⚠️  GPU command buffer timed out; restarting batch")
            return nil
        }
        
        if commandBuffer.status != .completed {
            if let error = commandBuffer.error {
                print("⚠️  GPU command buffer failed: \(error.localizedDescription)")
            } else {
                print("⚠️  GPU command buffer status: \(commandBuffer.status.rawValue)")
            }
            return nil
        }
        
        // Check results
        let validCount = buffers.validCountBuffer.contents().bindMemory(to: UInt32.self, capacity: 1).pointee
        if validCount > 0 {
            let validIndices = buffers.validIndicesBuffer.contents().bindMemory(to: UInt32.self, capacity: Int(validCount))
            let firstValidIndex = Int(validIndices[0])
            if firstValidIndex < count {
                let elapsed = Date().timeIntervalSince(batchStartTime)
                print("✅ GPU batch found valid work in \(String(format: "%.4f", elapsed))s")
                return startWork + UInt64(firstValidIndex)
            }
        }
        
        return nil
    }

    func selfTestGPUHash() async {
        guard let pipeline = computePipeline, let commandQueue = commandQueue else {
            print("⚠️  GPU hash self-test skipped (no pipeline)")
            return
        }
        let testHash = "E89208DD038FBB269987689621D52292FE9B863A173550C797762D7329D0E0F7"
        guard let hashData = Data(hexString: testHash) else {
            print("⚠️  GPU hash self-test failed (bad hash)")
            return
        }
        let work: UInt64 = 0
        let cpuInput = Data([UInt8](repeating: 0, count: 8)) + hashData
        let cpuHash = Blake2b.hash(cpuInput, outputLength: 8)
        let cpuH0 = workValueFromHash(cpuHash)
        
        if let gpuH0 = await computeGPUHash(startWork: work, blockHash: hashData, pipeline: pipeline, commandQueue: commandQueue) {
            print("🧪 GPU hash self-test h0: \(String(format: "%016llX", gpuH0))")
            print("🧪 CPU hash self-test h0: \(String(format: "%016llX", cpuH0))")
            if gpuH0 == cpuH0 {
                print("✅ GPU hash self-test matched CPU")
            } else {
                print("⚠️  GPU hash self-test mismatch")
            }
            fflush(stdout)
        } else {
            print("⚠️  GPU hash self-test failed (no result)")
        }
    }

    func computeGPUHash(startWork: UInt64, blockHash: Data, pipeline: MTLComputePipelineState, commandQueue: MTLCommandQueue) async -> UInt64? {
        let device = commandQueue.device
        guard let localQueue = device.makeCommandQueue() else { return nil }
        
        let count = 1
        if gpuBuffers == nil || gpuBuffers?.batchSize != count {
            guard let validIndicesBuffer = device.makeBuffer(length: 1024 * MemoryLayout<UInt32>.size, options: .storageModeShared),
                  let validCountBuffer = device.makeBuffer(length: MemoryLayout<UInt32>.size, options: .storageModeShared),
                  let hashBuffer = device.makeBuffer(length: count * MemoryLayout<UInt64>.size, options: .storageModeShared) else {
                return nil
            }
            gpuBuffers = GPUBuffers(batchSize: count, hashBuffer: hashBuffer, validIndicesBuffer: validIndicesBuffer, validCountBuffer: validCountBuffer)
        }
        guard let buffers = gpuBuffers else { return nil }
        buffers.validCountBuffer.contents().bindMemory(to: UInt32.self, capacity: 1).pointee = 0
        
        guard let commandBuffer = localQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }
        
        encoder.setComputePipelineState(pipeline)
        encoder.setBytes([startWork], length: MemoryLayout<UInt64>.size, index: 0)
        encoder.setBytes(Array(blockHash), length: blockHash.count, index: 1)
        encoder.setBuffer(buffers.hashBuffer, offset: 0, index: 2)
        encoder.setBuffer(buffers.validIndicesBuffer, offset: 0, index: 3)
        encoder.setBuffer(buffers.validCountBuffer, offset: 0, index: 4)
        encoder.setBytes([UInt32(count)], length: MemoryLayout<UInt32>.size, index: 5)
        encoder.setBytes([UInt64(0)], length: MemoryLayout<UInt64>.size, index: 6)
        
        let threadgroupSize = MTLSize(width: pipeline.threadExecutionWidth, height: 1, depth: 1)
        let threadgroupCount = MTLSize(width: (count + threadgroupSize.width - 1) / threadgroupSize.width, height: 1, depth: 1)
        encoder.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if commandBuffer.status != .completed {
            return nil
        }
        let hashPtr = buffers.hashBuffer.contents().bindMemory(to: UInt64.self, capacity: count)
        return hashPtr[0]
    }
    
    func computeChunk(startWork: UInt64, endWork: UInt64, blockHash: Data, threshold: UInt64) async -> UInt64? {
        // Nano PoW: Blake2b(work (8 bytes, big-endian) || block_hash (32 bytes))
        // Work must be 8 bytes in big-endian format
        var input = Data(count: 40)
        input.replaceSubrange(8..<40, with: blockHash)
        
        for workNonce in startWork..<endWork {
            // Write work to first 8 bytes (little-endian)
            withUnsafeBytes(of: workNonce.littleEndian) { bytes in
                input.replaceSubrange(0..<8, with: bytes)
            }
            
            // Compute Blake2b hash (64 bytes output)
            let hash = Blake2b.hash(input, outputLength: 8)
            
            // Check threshold: work value >= threshold
            let hashValue = workValueFromHash(hash)
            if hashValue >= threshold {
                return workNonce
            }
        }
        
        return nil
    }
    
    func workValueFromHash(_ hash: Data) -> UInt64 {
        // Nano uses the first 8 bytes of the hash as a little-endian UInt64
        var value: UInt64 = 0
        let count = min(8, hash.count)
        for i in 0..<count {
            value |= UInt64(hash[i]) << (UInt64(i) * 8)
        }
        return value
    }

    
    func selfTestBlake2b() {
        let testData = "abc".data(using: .utf8) ?? Data()
        let expected = "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923"
        let actual = Blake2b.hash(testData).map { String(format: "%02x", $0) }.joined()
        
        if actual == expected {
            print("✅ Blake2b self-test passed")
        } else {
            print("⚠️  Blake2b self-test failed")
            print("   Expected: \(expected)")
            print("   Actual:   \(actual.prefix(64))...")
        }
    }
    
    func leadingZeroBitsApprox(_ threshold: UInt64) -> Int {
        // Approximate: leading zeros in threshold
        return threshold.leadingZeroBitCount
    }
    

    private func resolvePort() -> UInt16 {
        if let argIndex = CommandLine.arguments.firstIndex(of: "--port"),
           CommandLine.arguments.count > argIndex + 1,
           let port = UInt16(CommandLine.arguments[argIndex + 1]) {
            return port
        }
        if let envPort = ProcessInfo.processInfo.environment["NANO_POW_PORT"],
           let port = UInt16(envPort) {
            return port
        }
        return 7077
    }
}

final class LocalPoWServer {
    private let generator: NanoPoWGenerator
    private let port: NWEndpoint.Port
    private var listener: NWListener?
    
    init(generator: NanoPoWGenerator, port: UInt16) {
        self.generator = generator
        self.port = NWEndpoint.Port(rawValue: port) ?? 7077
    }

    var portString: String {
        String(port.rawValue)
    }
    
    func start() {
        do {
            let listener = try NWListener(using: .tcp, on: port)
            listener.newConnectionHandler = { [weak self] connection in
                guard let self = self else { return }
                connection.start(queue: .global())
                Task {
                    await self.handle(connection: connection)
                }
            }
            listener.start(queue: .global())
            self.listener = listener
        } catch {
            print("❌ Failed to start local server: \(error.localizedDescription)")
        }
    }
    
    private func handle(connection: NWConnection) async {
        defer { connection.cancel() }
        guard let requestData = await receiveRequest(connection: connection) else {
            return
        }
        let response = await handleRequest(data: requestData)
        await sendResponse(connection: connection, body: response)
    }
    
    private func receiveRequest(connection: NWConnection) async -> Data? {
        var buffer = Data()
        var contentLength: Int?
        
        while true {
            let result = await receiveChunk(connection: connection)
            if let data = result.data, !data.isEmpty {
                buffer.append(data)
            }
            
            if contentLength == nil, let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headersData = buffer[..<headerEnd.lowerBound]
                let headersString = String(data: headersData, encoding: .utf8) ?? ""
                for line in headersString.split(separator: "\r\n") {
                    if line.lowercased().hasPrefix("content-length:") {
                        let parts = line.split(separator: ":", maxSplits: 1)
                        if parts.count == 2, let length = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
                            contentLength = length
                        }
                    }
                }
            }
            
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)), let length = contentLength {
                let bodyStart = headerEnd.upperBound
                if buffer.count >= bodyStart + length {
                    return buffer
                }
            }
            
            if result.isComplete || result.error != nil {
                return buffer.isEmpty ? nil : buffer
            }
        }
    }
    
    private func receiveChunk(connection: NWConnection) async -> (data: Data?, isComplete: Bool, error: NWError?) {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                continuation.resume(returning: (data, isComplete, error))
            }
        }
    }
    
    private func handleRequest(data: Data) async -> Data {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            return jsonResponse(["error": "Malformed HTTP request"])
        }
        let bodyStart = headerEnd.upperBound
        let bodyData = data.subdata(in: bodyStart..<data.count)
        
        guard let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let action = json["action"] as? String else {
            return jsonResponse(["error": "Invalid JSON body"])
        }
        
        switch action {
        case "work_generate":
            guard let hash = json["hash"] as? String else {
                return jsonResponse(["error": "Missing hash"])
            }
            if hash == ":FRONTIER" {
                return jsonResponse(["error": "Invalid frontier hash. Provide a 64-hex block hash."])
            }
            guard hash.count == 64, hash.range(of: "^[0-9A-Fa-f]{64}$", options: .regularExpression) != nil else {
                return jsonResponse(["error": "Invalid hash format. Expected 64-hex string."])
            }
            
            if let work = await generator.generateWork(for: hash) {
                let threshold: UInt64 = 0xfffffff93c41ec94
                return jsonResponse([
                    "work": work,
                    "difficulty": String(format: "%016llX", threshold)
                ])
            }
            return jsonResponse(["error": "Failed to generate work"])
        default:
            return jsonResponse(["error": "Unsupported action"])
        }
    }
    
    private func jsonResponse(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{\"error\":\"serialization\"}".utf8)
    }
    
    private func sendResponse(connection: NWConnection, body: Data) async {
        let headers = [
            "HTTP/1.1 200 OK",
            "Content-Type: application/json",
            "Content-Length: \(body.count)",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")
        var response = Data(headers.utf8)
        response.append(body)
        await withCheckedContinuation { continuation in
            connection.send(content: response, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }
}

extension Data {
    init?(hexString: String) {
        let len = hexString.count / 2
        var data = Data(capacity: len)
        var i = hexString.startIndex
        for _ in 0..<len {
            let j = hexString.index(i, offsetBy: 2)
            let bytes = hexString[i..<j]
            if var num = UInt8(bytes, radix: 16) {
                data.append(&num, count: 1)
            } else {
                return nil
            }
            i = j
        }
        self = data
    }
}

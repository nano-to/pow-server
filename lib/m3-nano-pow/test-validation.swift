#!/usr/bin/env swift

import Foundation

// Quick test of rpc.nano.to validation
let testHash = "E89208DD038FBB269987689621D52292FE9B863A173550C797762D7329D0E0F7"
let testWork = "0000000000000000" // Placeholder - this won't be valid, but tests the API

let url = URL(string: "https://rpc.nano.to")!
var request = URLRequest(url: url)
request.httpMethod = "POST"
request.setValue("application/json", forHTTPHeaderField: "Content-Type")

let requestBody: [String: Any] = [
    "action": "work_validate",
    "hash": testHash,
    "work": testWork
]

request.httpBody = try? JSONSerialization.data(withJSONObject: requestBody)

print("🧪 Testing rpc.nano.to work_validate API...")
print("Block hash: \(testHash)")
print("Work: \(testWork)")
print("")

let semaphore = DispatchSemaphore(value: 0)
var responseData: Data?
var responseError: Error?

URLSession.shared.dataTask(with: request) { data, response, error in
    responseData = data
    responseError = error
    
    if let httpResponse = response as? HTTPURLResponse {
        print("📡 Response status: \(httpResponse.statusCode)")
    }
    
    if let data = data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        print("📋 Response: \(json)")
        
        if let valid = json["valid"] {
            print("✅ Validation result: \(valid)")
        }
    } else if let error = error {
        print("❌ Error: \(error)")
    }
    
    semaphore.signal()
}.resume()

semaphore.wait()
print("\n✅ Test complete")

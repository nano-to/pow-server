#!/usr/bin/env swift

import Foundation

// Quick test of Blake2b
let testData = "hello".data(using: .utf8)!
let hash = Blake2b.hash(testData)
print("Blake2b test: \(hash.map { String(format: "%02x", $0) }.joined())")

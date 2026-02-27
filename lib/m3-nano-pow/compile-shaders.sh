#!/bin/bash

# Compile Metal shaders
cd "$(dirname "$0")"

echo "🔨 Compiling Metal shaders..."

xcrun -sdk macosx metal -c Sources/NanoPoW/Shaders.metal -o /tmp/shaders.air 2>&1
if [ $? -eq 0 ]; then
    xcrun -sdk macosx metallib /tmp/shaders.air -o Sources/NanoPoW/Default.metallib 2>&1
    if [ $? -eq 0 ]; then
        echo "✅ Shaders compiled successfully"
    else
        echo "❌ Failed to create metallib"
        exit 1
    fi
else
    echo "❌ Failed to compile Metal shaders"
    exit 1
fi

// swift-tools-version: 6.2
//
// xAIRealtimeKit — xAI Grok Voice Agent (realtime) client for Apple platforms.
//
// Full-duplex WebSocket session against wss://api.x.ai/v1/realtime — input audio
// buffer append + output audio deltas + tool/function calling. OpenAI-Realtime-
// compatible event protocol.
//
// Sister kits: xAITTSKit (one-shot synth), xAISTTKit (one-shot/streaming STT).
//

import PackageDescription

let package = Package(
    name: "xAIRealtimeKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(name: "xAIRealtimeKit", targets: ["xAIRealtimeKit"])
    ],
    targets: [
        .target(name: "xAIRealtimeKit", path: "Sources/xAIRealtimeKit"),
        .testTarget(name: "xAIRealtimeKitTests", dependencies: ["xAIRealtimeKit"], path: "Tests/xAIRealtimeKitTests")
    ],
    swiftLanguageModes: [.v6]
)

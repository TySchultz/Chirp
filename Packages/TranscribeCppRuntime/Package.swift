// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "TranscribeCppRuntime",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .library(name: "TranscribeCppRuntime", targets: ["TranscribeCppRuntime"])
  ],
  targets: [
    .binaryTarget(
      name: "CTranscribe",
      url: "https://github.com/handy-computer/transcribe.cpp/releases/download/v0.1.3/TranscribeCpp.xcframework.zip",
      checksum: "b7a3442e2f3552cac1ee71b5e164934dd4db243f6b4b16b1e3e3ed5d1645eefd"
    ),
    .target(
      name: "TranscribeCppRuntime",
      dependencies: ["CTranscribe"],
      linkerSettings: [
        .linkedLibrary("c++"),
        .linkedLibrary("z"),
        .linkedFramework("Accelerate"),
        .linkedFramework("Foundation"),
        .linkedFramework("Metal"),
        .linkedFramework("MetalKit")
      ]
    )
  ]
)

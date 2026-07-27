// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "ClaudeForFoundationModels",
  // Keep the package consumable by apps whose non-AI surfaces support older
  // deployment targets. Provider declarations are individually available
  // only on OS 27, where Foundation Models supports server-side models.
  platforms: [
    .iOS(.v26), .macOS(.v14), .visionOS(.v26), .watchOS(.v26),
  ],
  products: [
    .library(name: "ClaudeForFoundationModels", targets: ["ClaudeForFoundationModels"])
  ],
  targets: [
    // Internal Messages API client. No FoundationModels dependency.
    .target(name: "ClaudeAPI"),

    // FoundationModels ↔ Messages API bridge.
    .target(
      name: "ClaudeForFoundationModels",
      dependencies: ["ClaudeAPI"]
    ),

    // Runnable usage example (`swift run ClaudeExample`). Deliberately not a
    // product — it exists to document the SDK, not to be depended on.
    .executableTarget(
      name: "ClaudeExample",
      dependencies: ["ClaudeForFoundationModels"],
      path: "Examples/ClaudeExample"
    ),

    .testTarget(
      name: "ClaudeAPITests",
      dependencies: ["ClaudeAPI"]
    ),
    .testTarget(
      name: "ClaudeForFoundationModelsTests",
      dependencies: ["ClaudeForFoundationModels"]
    ),
  ]
)

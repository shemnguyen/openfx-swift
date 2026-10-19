// swift-tools-version: 5.9
//
// Swift Package Manager manifest for OpenFX.
//
// All Swift-specific code lives under `Swift/`; the OpenFX C headers in
// `include/` are used unmodified.
//
//   OpenFXC       The raw OpenFX C API (plus C shims for variadic functions).
//   OpenFX        Shared Swift bindings: status codes, typed constants, and a
//                 typed wrapper over a property suite.
//   OpenFXHost    A Swift implementation of the OpenFX host API: the suites,
//                 parameters, clips and images that plug-ins run against.
//   OpenFXPlugin  Write OpenFX image effect *plug-ins* in Swift.
//   OpenFXRemote  The XPC protocol between host apps and plug-in processes.
//   OpenFXExtensionKit  For host apps: discover, launch and use OpenFX plug-ins
//                 vended by app extensions. Host apps never load plug-in code.
//   OpenFXAppExtension  For plug-in vendors: an app extension that runs
//                 OpenFX plug-ins (Swift, linked C/C++, or `.ofx.bundle`s
//                 shipped inside it) and serves them to host apps.

import PackageDescription

let package = Package(
  name: "OpenFX",
  platforms: [.macOS(.v13)],
  products: [
    .library(name: "OpenFXC", targets: ["OpenFXC"]),
    .library(name: "OpenFX", targets: ["OpenFX"]),
    .library(name: "OpenFXHost", targets: ["OpenFXHost"]),
    .library(name: "OpenFXPlugin", targets: ["OpenFXPlugin"]),
    .library(name: "OpenFXRemote", targets: ["OpenFXRemote"]),
    .library(name: "OpenFXExtensionKit", targets: ["OpenFXExtensionKit"]),
    .library(name: "OpenFXAppExtension", targets: ["OpenFXAppExtension"]),
  ],
  targets: [
    .target(
      name: "OpenFXC",
      path: "Swift/Sources/OpenFXC"
    ),
    .target(
      name: "OpenFX",
      dependencies: ["OpenFXC"],
      path: "Swift/Sources/OpenFX"
    ),
    .target(
      name: "OpenFXHost",
      dependencies: ["OpenFX"],
      path: "Swift/Sources/OpenFXHost"
    ),
    .target(
      name: "OpenFXPlugin",
      dependencies: ["OpenFX"],
      path: "Swift/Sources/OpenFXPlugin"
    ),
    .target(
      name: "OpenFXRemote",
      dependencies: ["OpenFXHost"],
      path: "Swift/Sources/OpenFXRemote"
    ),
    .target(
      name: "OpenFXExtensionKit",
      dependencies: ["OpenFXRemote"],
      path: "Swift/Sources/OpenFXExtensionKit"
    ),
    .target(
      name: "OpenFXAppExtension",
      dependencies: ["OpenFXRemote"],
      path: "Swift/Sources/OpenFXAppExtension"
    ),
    .testTarget(
      name: "OpenFXTests",
      dependencies: ["OpenFX", "OpenFXHost", "OpenFXPlugin", "OpenFXRemote"],
      path: "Swift/Tests/OpenFXTests"
    ),
  ]
)

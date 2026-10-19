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
//   OpenFXHost    A Swift implementation of an OpenFX *host*: load `.ofx`
//                 bundles and run image effect plug-ins inside your app.
//   OpenFXPlugin  Write OpenFX image effect *plug-ins* in Swift.

import PackageDescription

let package = Package(
  name: "OpenFX",
  platforms: [.macOS(.v13)],
  products: [
    .library(name: "OpenFXC", targets: ["OpenFXC"]),
    .library(name: "OpenFX", targets: ["OpenFX"]),
    .library(name: "OpenFXHost", targets: ["OpenFXHost"]),
    .library(name: "OpenFXPlugin", targets: ["OpenFXPlugin"]),
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
    .testTarget(
      name: "OpenFXTests",
      dependencies: ["OpenFX", "OpenFXHost", "OpenFXPlugin"],
      path: "Swift/Tests/OpenFXTests"
    ),
  ]
)

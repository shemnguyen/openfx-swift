# OpenFX for Swift

Swift Package Manager support and Swift bindings for OpenFX. Everything
Swift-specific lives in this `Swift/` folder plus the root `Package.swift`;
the OpenFX headers in `../include` are used unmodified.

```swift
.package(url: "https://github.com/shemnguyen/openfx-swift", branch: "main")
```

| Product        | What it is |
|----------------|------------|
| `OpenFXC`      | The raw OpenFX C API (`ofxCore.h`, `ofxImageEffect.h`, ...) as a Clang module, plus C shims for the variadic functions Swift can't call or implement. |
| `OpenFX`       | Shared Swift layer: `OFXStatus` (an `Error`), typed constants (`OFXAction`, `OFXImageEffectContext`, `OFXBitDepth`, `OFXParamType`, ...), geometry helpers, and `OFXPropertySetRef`, a typed wrapper over any property suite. |
| `OpenFXHost`   | An OpenFX **host** in Swift: load `.ofx.bundle`s and run image effect plug-ins inside your app. |
| `OpenFXPlugin` | Write OpenFX image effect **plug-ins** in Swift and export them as a bundle any OpenFX host can load. |

Each higher-level module re-exports `OpenFX` (and through it `OpenFXC`), so one
import is enough.

## Hosting plug-ins

```swift
import OpenFXHost

let host = OFXHost(configuration: .init(name: "com.example.editor", label: "My Editor"))
host.loadPlugins(in: URL(fileURLWithPath: "/Library/OFX/Plugins"))

let plugin = host.plugin(withIdentifier: "uk.co.thefoundry.BasicGainPlugin")!
print(plugin.label, plugin.supportedContexts)

let instance = try plugin.createInstance(project: OFXProject(width: 1920, height: 1080))
try instance.setInput(image: OFXImageBuffer(cgImage: frame)!)   // or setInput(source:) per-time
try instance.setValue(.double(0.5), for: "scale")              // notifies the plug-in
try instance.setValue(.double(2), for: "scale", at: 24)        // keyframe
let output: OFXImageBuffer = try instance.render(time: 12)
let cgImage = output.makeCGImage()
```

What the host provides:

* **Suites:** property, image effect, parameter (with keyframes, derivatives and
  integrals), memory, multi-thread, message (V1/V2), progress (V1/V2), timeline,
  and interact (stub).
* **Contexts:** filter, general, generator, transition and retimer.
* **Pixels:** byte, short and float, in RGBA, RGB or Alpha. Sources are converted
  to whatever depth and components the plug-in negotiates in
  `kOfxImageEffectActionGetClipPreferences`, including re-negotiation when a
  `kOfxImageEffectPropClipPreferencesSlaveParam` changes.
* **Actions:** the full lifecycle: load, describe, describe-in-context,
  create/destroy instance, instance changed (begin/end), region of definition,
  is-identity (passes the source through), begin/end sequence render, render.
* **Parameters:** every value type, with normalised spatial defaults converted
  to canonical coordinates. Plug-in edits are reported through
  `onParameterChangedByPlugin`.

Not implemented yet: overlay interacts and the draw suite, custom parameter
interpolation, parametric parameters, GPU (OpenGL/Metal/CUDA/OpenCL) rendering,
render scale (renders are always full resolution), and colour management.

## Writing plug-ins in Swift

```swift
import OpenFXPlugin

final class Gain: OFXEffectPlugin {
  static let identifier = "com.example.Gain"

  static func describe(_ effect: OFXEffectRef) throws {
    try effect.setDescription(label: "Gain", contexts: [.filter], pixelDepths: [.float])
  }

  static func describeInContext(_ effect: OFXEffectRef, context: OFXImageEffectContext) throws {
    try effect.defineClip(kOfxImageEffectSimpleSourceClipName)
    try effect.defineClip(kOfxImageEffectOutputClipName)
    try effect.defineDouble("gain", label: "Gain", default: 1, range: 0...4)
  }

  let effect: OFXEffectRef
  init(effect: OFXEffectRef) throws { self.effect = effect }

  func render(_ args: OFXRenderArguments) throws {
    let gain = Float(try effect.parameter("gain").double(at: args.time))
    let src = try effect.clip(kOfxImageEffectSimpleSourceClipName).image(at: args.time)
    defer { src.release() }
    let dst = try effect.clip(kOfxImageEffectOutputClipName).image(at: args.time)
    defer { dst.release() }
    // ... read src.pixelAddress(x:y:), write dst.pixelAddress(x:y:) ...
  }
}

// The two C entry points every OpenFX binary exports:
let registry = OFXPluginRegistry([Gain.self])
@_cdecl("OfxGetNumberOfPlugins") public func OfxGetNumberOfPlugins() -> Int32 { registry.count }
@_cdecl("OfxGetPlugin") public func OfxGetPlugin(_ n: Int32) -> UnsafeMutablePointer<OfxPlugin>? {
  registry.plugin(at: n)
}
```

Build the target as a `.dynamic` library product and package the dylib as
`Name.ofx.bundle/Contents/MacOS/Name.ofx` (see `OpenFX-app/scripts/build-plugins.sh`).
A registry can also be handed straight to an in-process `OFXHost` with
`host.register(plugin:)`, which is how this package's tests run.

One binary can export up to 16 Swift plug-ins. OpenFX identifies a plug-in only
by its C entry point function, and Swift can't create new C function pointers at
run time, so there is a fixed table of entry points.

## Layout

```
Package.swift                     SwiftPM manifest (repo root)
Swift/Sources/OpenFXC/            umbrella header over ../include + variadic C shims
Swift/Sources/OpenFX/             status, constants, geometry, OFXPropertySetRef
Swift/Sources/OpenFXHost/         OFXHost, plug-in/bundle loading, suites, image buffers
Swift/Sources/OpenFXPlugin/       OFXEffectPlugin protocol, registry, plug-in-side refs
Swift/Tests/OpenFXTests/          host suites + Swift plug-ins run in-process
```

### The C shims

`paramGetValue`/`paramSetValue` (and the `AtTime`, derivative and integral
variants) and the message suite are C variadic functions, which Swift can
neither implement nor call. `OpenFXSwiftShims.c` bridges both directions:

* **Host side:** C trampolines fill the variadic slots of the host's suite
  structs. They ask Swift for the parameter's value layout (kind and count), then
  move values between `va_list` and a fixed `OfxSwiftParamValue`.
* **Plug-in side:** `OfxSwiftCallParamGetValue` and related functions call a
  host's variadic functions with an explicit layout.

## Testing

```sh
swift test
```

`OpenFX-app` (next to this repo) has tests that build and load real C, C++ and
Swift plug-in bundles through `dlopen`.

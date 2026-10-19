# OpenFX for Swift

Swift Package Manager support and Swift bindings for OpenFX. Everything
Swift-specific lives in this `Swift/` folder plus the root `Package.swift`;
the OpenFX headers in `../include` are used unmodified.

```swift
.package(url: "https://github.com/shemnguyen/openfx-swift", branch: "main")
```

Host apps use OpenFX plug-ins **only through app extensions** (ExtensionKit).
A host app never loads plug-in code: each plug-in vendor ships an app containing
an extension, and the plug-ins run inside that sandboxed extension process. That
keeps host apps within App Store rules, which don't allow loading code App
Review hasn't seen.

| Product | Used by | What it is |
|---|---|---|
| `OpenFXExtensionKit` | host apps | Discover, approve and launch plug-in extensions (`OFXExtensionLibrary`, `OFXExtensionBrowser`), and use their effects (`OFXRemoteEffect`, `OFXRemoteInstance`). |
| `OpenFXAppExtension` | plug-in vendors | An app extension that runs OpenFX plug-ins and serves them to host apps (`OFXAppExtension`). The plug-ins can be Swift, linked C/C++, or unmodified `.ofx.bundle`s shipped inside the extension (`OFXEmbeddedPlugins`). |
| `OpenFXPlugin` | plug-in vendors | Write OpenFX image effect plug-ins in Swift (`OFXEffectPlugin`, `OFXPluginRegistry`). |
| `OpenFXRemote` | both (via the above) | The XPC protocol between them: `OFXRemoteServer`, `OFXRemoteClient`, IOSurface frames. |
| `OpenFXHost` | both (via the above) | The OpenFX host implementation that runs inside the extension (suites, clips, parameters, images), plus the `OFXEffect` protocols and the value types host apps work with (`OFXImageBuffer`, `OFXParameter`, `OFXProject`). |
| `OpenFX`, `OpenFXC` | everything | The raw C API as a Clang module (with C shims for its variadic functions) and the shared Swift layer: `OFXStatus`, typed constants, `OFXPropertySetRef`. |

Higher-level modules re-export the lower ones, so one import is usually enough.

## Architecture

OpenFX is an in-process C API. A host maps the plug-in binary into its own
address space and calls `OfxGetPlugin` to get C function pointers. Every handle
is a raw pointer, images are shared by pointer, and during each action the
plug-in calls back into the host's suites synchronously, often hundreds of
times per frame.

This package splits the host in two, the same shape Apple's FxPlug 4 uses for
Final Cut Pro:

```
 Host app (sandboxed, no plug-in code)          Vendor's app extension (sandboxed, own process)
┌────────────────────────────────────┐  XPC    ┌───────────────────────────────────────────────┐
│ OFXExtensionLibrary                │◄───────►│ OFXAppExtension → OFXRemoteServer             │
│   AppExtensionPoint.Monitor        │         │   OFXHost (OpenFXHost) — a real OpenFX host   │
│   AppExtensionProcess per extension│         │     ├─ Swift / statically linked plug-ins     │
│ OFXRemoteEffect / OFXRemoteInstance│ IOSurf. │     └─ .ofx.bundles in its own Contents/PlugIns│
│   local mirror of parameters       │◄───────►│   all fine-grained suite calls stay in here   │
└────────────────────────────────────┘ frames  └───────────────────────────────────────────────┘
```

* **Only coarse operations cross the process boundary:** describe, create/destroy
  instance, edit (set value or keyframe, press button, connect input, set time),
  render and abort, plus two callbacks from the extension: *fetch input frame
  (clip, time)* and *post message*. Payloads are property-list encoded
  `OFXWire` values.
* **Frames are IOSurfaces** (shared memory), so pixels are never copied through
  XPC. The extension pulls input frames when the plug-in asks for them, which
  keeps temporal access (retimers and the like) working.
* **Parameters are mirrored** into ordinary `OFXParameter` objects, including
  keyframes, so host UI reads them locally. Values the plug-in writes itself
  come back in the edit reply.
* **Crashes are contained.** If the extension dies, the host app keeps running,
  and the next call relaunches the extension and re-creates the instance from
  the mirrored state.
* **Bundle loading (`dlopen`) exists only in `OpenFXAppExtension`**, which host
  apps don't link. It loads only bundles shipped inside the extension's own
  signed bundle.

## Host apps

```swift
import ExtensionFoundation
import OpenFXExtensionKit

// In the app target. Xcode turns this into bundle metadata.
extension AppExtensionPoint {
  @Definition static var openFXImageEffect: AppExtensionPoint {
    Name("OpenFXImageEffect")
    UserInterface(false)
    Scope(restriction: .none)          // extensions may ship in other developers' apps
  }
}

let library = OFXExtensionLibrary()
try await library.start(extensionPoint: .openFXImageEffect)
// library.effects updates as extensions are installed, enabled or disabled.
// If library.unapprovedCount > 0, show OFXExtensionBrowser so the user can enable them.

let effect = library.effects[0]                              // an OFXEffect
let instance = try effect.makeInstance(project: OFXProject(width: 1920, height: 1080))
try instance.setInput(image: OFXImageBuffer(cgImage: frame)!)  // or setInput(name, source: { time in ... })
try instance.setValue(.double(0.5), for: "scale")             // notifies the plug-in
try instance.setValue(.double(2), for: "scale", at: 24)       // keyframe
let output: OFXImageBuffer = try instance.render(time: 12)    // rendered in the extension
let cgImage = output.makeCGImage()
```

Calls into an extension are synchronous (with a timeout), so make them off the
main thread.

## Plug-in vendors: the extension

Add an Xcode "Generic Extension" (Non-UI) target to your app:

```swift
import ExtensionFoundation
import OpenFXAppExtension

@main
struct MyEffects: OFXAppExtension {
  @AppExtensionPoint.Bind
  var extensionPoint: AppExtensionPoint {
    AppExtensionPoint.Identifier(host: "com.example.editor", name: "OpenFXImageEffect")
  }

  func registerPlugins(in host: OFXHost) -> [String] {
    for p in myRegistry.allPlugins { host.register(plugin: p) }   // Swift / linked plug-ins
    return OFXEmbeddedPlugins.load(into: host)                   // Contents/PlugIns/*.ofx.bundle
  }
}
```

Both the host app and the extension need the
`EX_ENABLE_EXTENSION_POINT_GENERATION = YES` build setting. Xcode then writes
the definition into `Host.app/Contents/Extensions/*.appexpt` and the binding
into the extension's `Info.plist`, with identifier `<host bundle id>.<name>`.

The OpenFX host running inside the extension provides:

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
  to canonical coordinates.

Not implemented yet: overlay interacts and the draw suite, custom parameter
interpolation, parametric parameters, GPU (OpenGL/Metal/CUDA/OpenCL) rendering,
render scale (renders are always full resolution), and colour management.

### Writing plug-ins in Swift

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

let myRegistry = OFXPluginRegistry([Gain.self])   // registered by the extension, as above
```

A registry is a set of real OpenFX `OfxPlugin` entry points. One registry can
hold up to 16 Swift plug-ins: OpenFX identifies a plug-in only by its C entry
point, and Swift can't create C function pointers at run time, so there is a
fixed table of them.

### Things to know

* **Users approve extensions.** Extensions that ship outside the host app are
  disabled until the user enables them, through `OFXExtensionBrowser`
  (`EXAppExtensionBrowserViewController`) or System Settings.
* **One extension per host.** Each host app defines its own extension point,
  and an extension binds to exactly one. A vendor ships one small extension
  target per host app it supports. They can share all their code.
* **macOS 26 or later.** It needs `AppExtensionPoint.Monitor`, `@Definition`,
  `@Bind` and `ConnectionHandler`. `Scope(restriction: .none)` is macOS-only.
* **Not yet carried across:** overlay interacts (these would need ExtensionKit
  UI, `EXHostViewController`), changes plug-ins make to parameter *properties*
  at run time (labels, enabled, secret; values are carried), and
  `EnhancedSecurity` extension points, which expect the XPC framework's
  `XPCSession` rather than `NSXPCConnection`.

For working examples, see `OpenFX-app` (a host app) and `OpenFX-plugins/VendorApp`
(a vendor app and its extension).

## Layout

```
Package.swift                     SwiftPM manifest (repo root)
Swift/Sources/OpenFXC/            umbrella header over ../include + variadic C shims
Swift/Sources/OpenFX/             status, constants, geometry, OFXPropertySetRef
Swift/Sources/OpenFXHost/         the OpenFX host implementation, OFXEffect protocols, image buffers
Swift/Sources/OpenFXPlugin/       OFXEffectPlugin protocol, registry, plug-in-side refs
Swift/Sources/OpenFXRemote/       XPC protocol, IOSurface frames, OFXRemoteServer/OFXRemoteClient
Swift/Sources/OpenFXExtensionKit/ host apps: OFXExtensionLibrary, OFXExtensionBrowser
Swift/Sources/OpenFXAppExtension/ extensions: OFXAppExtension, OFXEmbeddedPlugins, OFXPluginBundle
Swift/Tests/OpenFXTests/          the host suites, Swift plug-ins, and the XPC protocol end to end
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

`OpenFX-plugins` (next to this repo) has tests that serve real C, C++ and Swift
plug-ins the way its app extension does, and use them over XPC.

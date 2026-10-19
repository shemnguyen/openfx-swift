// Copyright OpenFX and contributors to the OpenFX project.
// SPDX-License-Identifier: BSD-3-Clause

import Foundation
import OpenFX

/// One OpenFX image effect plug-in, from a bundle or registered in-process.
///
/// The plug-in is loaded and described lazily: the first call that needs its
/// description runs `setHost`, `kOfxActionLoad` and `kOfxActionDescribe`.
public final class OFXImageEffectPlugin: @unchecked Sendable {
  public enum State: Equatable {
    case unloaded
    case described
    case failed(OFXStatus)
  }

  public let identifier: String
  public let versionMajor: UInt32
  public let versionMinor: UInt32
  public let apiVersion: Int32
  /// The bundle the plug-in came from (nil for in-process plug-ins).
  public let bundle: OFXPluginBundle?
  public unowned let host: OFXHost

  public private(set) var state: State = .unloaded
  private var mainDescriptor: OFXImageEffect?
  private var contextDescriptors: [OFXImageEffectContext: OFXImageEffect] = [:]
  private let raw: UnsafeMutablePointer<OfxPlugin>
  private let lock = NSRecursiveLock()

  init(raw: UnsafeMutablePointer<OfxPlugin>, bundle: OFXPluginBundle?, host: OFXHost) {
    self.raw = raw
    self.bundle = bundle
    self.host = host
    self.identifier = raw.pointee.pluginIdentifier.map { String(cString: $0) } ?? "<unnamed>"
    self.versionMajor = raw.pointee.pluginVersionMajor
    self.versionMinor = raw.pointee.pluginVersionMinor
    self.apiVersion = raw.pointee.apiVersion
  }

  deinit {
    if state == .described { _ = callAction(.unload, handle: nil, inArgs: nil, outArgs: nil) }
  }

  // MARK: Description

  /// Loads and describes the plug-in if needed and returns its global descriptor.
  @discardableResult
  public func describe() throws -> OFXImageEffect {
    try lock.locked {
      switch state {
      case .described: return mainDescriptor!
      case .failed(let s): throw s
      case .unloaded: break
      }
      do {
        raw.pointee.setHost?(host.rawHost)
        var stat = callAction(.load, handle: nil, inArgs: nil, outArgs: nil)
        guard stat == kOfxStatOK || stat == kOfxStatReplyDefault else { throw OFXStatus(stat) }

        let descriptor = OFXImageEffect(plugin: self, properties: OFXImageEffect.descriptorProperties(plugin: self))
        stat = callAction(.describe, handle: descriptor, inArgs: nil, outArgs: nil)
        guard stat == kOfxStatOK || stat == kOfxStatReplyDefault else {
          _ = callAction(.unload, handle: nil, inArgs: nil, outArgs: nil)
          throw OFXStatus(stat)
        }
        mainDescriptor = descriptor
        state = .described
        return descriptor
      } catch {
        state = .failed(error as? OFXStatus ?? .failed)
        throw error
      }
    }
  }

  /// The descriptor for one context, running `kOfxImageEffectActionDescribeInContext` on first use.
  public func descriptor(for context: OFXImageEffectContext) throws -> OFXImageEffect {
    try lock.locked {
      if let d = contextDescriptors[context] { return d }
      let main = try describe()
      guard main.supportedContexts.contains(context) else { throw OFXStatus.errUnsupported }
      guard host.configuration.supportedContexts.contains(context) else { throw OFXStatus.errMissingHostFeature }

      let props = OFXPropertySet(debugName: "context descriptor \(identifier) \(context)")
      props.copyProperties(from: main.properties)
      props.define(kOfxImageEffectPropContext, .string([context.rawValue]), readOnly: true)
      let d = OFXImageEffect(plugin: self, properties: props)
      let inArgs = OFXPropertySet(debugName: "describe in context")
      inArgs.set(kOfxImageEffectPropContext, context.rawValue)
      let stat = callAction(.describeInContext, handle: d, inArgs: inArgs, outArgs: nil)
      guard stat == kOfxStatOK || stat == kOfxStatReplyDefault else { throw OFXStatus(stat) }
      contextDescriptors[context] = d
      return d
    }
  }

  public var label: String { (try? describe())?.label ?? identifier }
  public var grouping: String { (try? describe())?.grouping ?? "" }
  public var supportedContexts: [OFXImageEffectContext] { (try? describe())?.supportedContexts ?? [] }

  /// The first context both this plug-in and the host support, preferring filter.
  public var preferredContext: OFXImageEffectContext? {
    let mine = supportedContexts
    return [.filter, .general, .generator, .transition, .retimer].first {
      mine.contains($0) && host.configuration.supportedContexts.contains($0)
    }
  }

  // MARK: Instances

  /// Creates and initialises an instance.
  ///
  /// - Parameter preferredBitDepth: the depth clips run at when the plug-in supports it.
  public func createInstance(context: OFXImageEffectContext? = nil, project: OFXProject,
                             preferredBitDepth: OFXBitDepth = .float) throws -> OFXImageEffectInstance {
    guard let context = context ?? preferredContext else { throw OFXStatus.errUnsupported }
    let d = try descriptor(for: context)
    let instance = OFXImageEffectInstance(plugin: self, descriptor: d, context: context, project: project,
                                          preferredBitDepth: preferredBitDepth)
    try instance.create()
    return instance
  }

  // MARK: Actions

  /// Calls the plug-in's main entry point.
  public func callAction(_ action: OFXAction, handle: OFXImageEffect?, inArgs: OFXPropertySet?,
                         outArgs: OFXPropertySet?) -> OfxStatus {
    guard let main = raw.pointee.mainEntry else { return kOfxStatErrMissingHostFeature }
    let h: UnsafeRawPointer? = handle.map { UnsafeRawPointer(Unmanaged.passUnretained($0).toOpaque()) }
    return withExtendedLifetime((handle, inArgs, outArgs)) {
      action.rawValue.withCString { main($0, h, inArgs?.handle, outArgs?.handle) }
    }
  }
}

/// A loaded `.ofx.bundle` and the plug-ins it contains.
public final class OFXPluginBundle {
  public let url: URL
  public let binaryURL: URL
  /// Image effect plug-ins in the bundle that this host can run.
  public private(set) var plugins: [OFXImageEffectPlugin] = []
  /// Plug-ins in the bundle implementing other APIs or versions, as (identifier, API).
  public private(set) var unsupportedPlugins: [(identifier: String, api: String)] = []

  private let library: UnsafeMutableRawPointer

  public enum LoadError: Error, CustomStringConvertible {
    case binaryNotFound(URL)
    case dlopenFailed(URL, String)
    case missingEntryPoints(URL)
    case setHostFailed(URL, OFXStatus)

    public var description: String {
      switch self {
      case .binaryNotFound(let u): return "no OpenFX binary found in \(u.path)"
      case .dlopenFailed(let u, let e): return "could not load \(u.path): \(e)"
      case .missingEntryPoints(let u): return "\(u.path) does not export OfxGetNumberOfPlugins/OfxGetPlugin"
      case .setHostFailed(let u, let s): return "OfxSetHost failed for \(u.path): \(s)"
      }
    }
  }

  private typealias GetNumberFn = @convention(c) () -> Int32
  private typealias GetPluginFn = @convention(c) (Int32) -> UnsafeMutablePointer<OfxPlugin>?
  private typealias SetHostFn = @convention(c) (UnsafePointer<OfxHost>?) -> OfxStatus

  init(url: URL, host: OFXHost) throws {
    self.url = url
    guard let binary = Self.binaryURL(forBundle: url) else { throw LoadError.binaryNotFound(url) }
    self.binaryURL = binary
    guard let lib = dlopen(binary.path, RTLD_NOW | RTLD_LOCAL) else {
      throw LoadError.dlopenFailed(binary, dlerror().map { String(cString: $0) } ?? "unknown error")
    }
    self.library = lib
    // Plug-in binaries are deliberately never dlclose'd: many plug-ins are not
    // written to be unloaded, and suites/handles they cached would dangle.

    guard let getNumberSym = dlsym(lib, "OfxGetNumberOfPlugins"),
          let getPluginSym = dlsym(lib, "OfxGetPlugin")
    else { throw LoadError.missingEntryPoints(binary) }

    if let setHostSym = dlsym(lib, "OfxSetHost") {
      let setHost = unsafeBitCast(setHostSym, to: SetHostFn.self)
      let stat = setHost(UnsafePointer(host.rawHost))
      guard stat == kOfxStatOK || stat == kOfxStatReplyDefault else {
        throw LoadError.setHostFailed(binary, OFXStatus(stat))
      }
    }

    let getNumber = unsafeBitCast(getNumberSym, to: GetNumberFn.self)
    let getPlugin = unsafeBitCast(getPluginSym, to: GetPluginFn.self)
    let n = getNumber()
    for i in 0..<max(n, 0) {
      guard let raw = getPlugin(i) else { continue }
      let api = raw.pointee.pluginApi.map { String(cString: $0) } ?? ""
      if api == kOfxImageEffectPluginApi && raw.pointee.apiVersion == 1 {
        plugins.append(OFXImageEffectPlugin(raw: raw, bundle: self, host: host))
      } else {
        let id = raw.pointee.pluginIdentifier.map { String(cString: $0) } ?? "<unnamed>"
        unsupportedPlugins.append((id, "\(api) v\(raw.pointee.apiVersion)"))
      }
    }
  }

  /// Architecture directories searched inside `Contents/`, most specific first.
  static var architectureDirectories: [String] {
    #if os(macOS)
    return ["MacOS"]
    #elseif os(Linux)
    #if arch(arm64)
    return ["Linux-arm64", "Linux-aarch64"]
    #else
    return ["Linux-x86-64", "Linux-x86"]
    #endif
    #elseif os(Windows)
    return ["Win64", "Win32"]
    #else
    return []
    #endif
  }

  /// Locates `Contents/<arch>/<name>.ofx` inside a bundle.
  public static func binaryURL(forBundle url: URL) -> URL? {
    let fm = FileManager.default
    var name = url.lastPathComponent
    if name.hasSuffix(".bundle") { name = String(name.dropLast(".bundle".count)) }
    if !name.hasSuffix(".ofx") { name += ".ofx" }
    for dir in architectureDirectories {
      let base = url.appendingPathComponent("Contents").appendingPathComponent(dir)
      let exact = base.appendingPathComponent(name)
      if fm.fileExists(atPath: exact.path) { return exact }
      // Fall back to any .ofx file, for bundles whose binary is named differently.
      if let any = (try? fm.contentsOfDirectory(atPath: base.path))?.sorted().first(where: { $0.hasSuffix(".ofx") }) {
        return base.appendingPathComponent(any)
      }
    }
    return nil
  }
}

// Copyright OpenFX and contributors to the OpenFX project.
// SPDX-License-Identifier: BSD-3-Clause

import Foundation
import OpenFXHost

/// A loaded `.ofx.bundle` and the plug-ins it contains.
///
/// This is the only place OpenFX plug-in binaries are `dlopen`ed, and it lives in
/// the app-extension module: an extension may load bundles shipped inside its own
/// signed bundle (see `OFXEmbeddedPlugins`). Host apps never link it.
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

  public init(url: URL, host: OFXHost) throws {
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
      let stat = setHost(host.hostPointer)
      guard stat == kOfxStatOK || stat == kOfxStatReplyDefault else {
        throw LoadError.setHostFailed(binary, OFXStatus(stat))
      }
    }

    let getNumber = unsafeBitCast(getNumberSym, to: GetNumberFn.self)
    let getPlugin = unsafeBitCast(getPluginSym, to: GetPluginFn.self)
    let n = getNumber()
    for i in 0..<max(n, 0) {
      guard let raw = getPlugin(i) else { continue }
      if let plugin = host.register(plugin: raw, origin: url.lastPathComponent, filePath: url.path) {
        plugins.append(plugin)
      } else {
        let api = raw.pointee.pluginApi.map { String(cString: $0) } ?? ""
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

  /// Recursively finds and loads every `.ofx.bundle` in `directory` into `host`.
  ///
  /// - Returns: the bundles that loaded, and the errors for those that did not.
  @discardableResult
  public static func loadAll(in directory: URL, into host: OFXHost)
    -> (loaded: [OFXPluginBundle], failures: [(URL, Error)])
  {
    var loaded: [OFXPluginBundle] = []
    var failures: [(URL, Error)] = []
    for url in findBundles(in: directory) {
      do { loaded.append(try OFXPluginBundle(url: url.standardizedFileURL, host: host)) } catch {
        failures.append((url, error))
      }
    }
    return (loaded, failures)
  }

  /// The `.ofx.bundle`s in `directory` and its subdirectories, sorted by path.
  public static func findBundles(in directory: URL) -> [URL] {
    let fm = FileManager.default
    guard let e = fm.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                                options: [.skipsHiddenFiles]) else { return [] }
    var found: [URL] = []
    for case let url as URL in e where url.lastPathComponent.hasSuffix(".ofx.bundle") {
      found.append(url)
      e.skipDescendants()
    }
    return found.sorted { $0.path < $1.path }
  }
}

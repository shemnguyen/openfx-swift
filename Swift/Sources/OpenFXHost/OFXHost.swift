// Copyright OpenFX and contributors to the OpenFX project.
// SPDX-License-Identifier: BSD-3-Clause

import Foundation
import OpenFX

/// A message posted by a plug-in through the message suite.
public struct OFXMessage: CustomStringConvertible {
  public var type: OFXMessageType
  public var id: String?
  public var text: String
  /// True for `setPersistentMessage`.
  public var isPersistent: Bool
  /// The plug-in that posted the message, when the handle identified one.
  public weak var effect: OFXImageEffect?

  public var description: String {
    let who = effect.map { " [\($0.plugin.identifier)]" } ?? ""
    return "OFX \(type.rawValue.replacingOccurrences(of: "OfxMessage", with: ""))\(who): \(text)"
  }
}

/// An OpenFX host. Create one per application and keep it alive for as long
/// as plug-ins are in use (plug-ins cache the host pointer they are given).
///
/// ```swift
/// let host = OFXHost()
/// try host.loadPlugins(in: URL(fileURLWithPath: "/Library/OFX/Plugins"))
/// for plugin in host.plugins { print(plugin.identifier, plugin.label) }
/// ```
public final class OFXHost: @unchecked Sendable {
  public struct Configuration {
    /// Reverse-domain identifier of the host application (`kOfxPropName`).
    public var name: String
    /// Human readable host name (`kOfxPropLabel`).
    public var label: String
    public var version: (major: Int, minor: Int, micro: Int)
    public var supportedContexts: [OFXImageEffectContext]
    /// Whether the host is a background renderer (`kOfxImageEffectHostPropIsBackground`).
    public var isBackground: Bool

    public init(name: String = "org.openeffects.openfx-swift", label: String = "OpenFX Swift Host",
                version: (major: Int, minor: Int, micro: Int) = (1, 0, 0),
                supportedContexts: [OFXImageEffectContext] = [.filter, .general, .generator, .transition, .retimer],
                isBackground: Bool = false) {
      self.name = name
      self.label = label
      self.version = version
      self.supportedContexts = supportedContexts
      self.isBackground = isBackground
    }
  }

  public let configuration: Configuration
  /// The host descriptor (`OfxHost::host`).
  public let properties = OFXPropertySet(debugName: "host")
  let rawHost: UnsafeMutablePointer<OfxHost>

  /// Receives plug-in messages. Return `.replyYes`/`.replyNo` for questions.
  /// The default logs to standard error and answers questions with yes.
  public var messageHandler: (OFXMessage) -> OFXStatus = { message in
    FileHandle.standardError.write((message.description + "\n").data(using: .utf8)!)
    return message.type == .question ? .replyYes : .ok
  }

  public private(set) var bundles: [OFXPluginBundle] = []
  private var inProcessPlugins: [OFXImageEffectPlugin] = []
  private let lock = NSRecursiveLock()

  /// The most recently created host, which receives messages posted without an effect handle.
  static weak var current: OFXHost?

  public init(configuration: Configuration = Configuration()) {
    self.configuration = configuration
    OFXHostSuites.installCallbacks()
    rawHost = .allocate(capacity: 1)
    rawHost.initialize(to: OfxHost(host: properties.handle, fetchSuite: OFXHostSuites.fetchSuite))
    describeHost()
    OFXHost.current = self
  }

  deinit {
    rawHost.deinitialize(count: 1)
    rawHost.deallocate()
  }

  /// All image effect plug-ins known to the host, in load order.
  public var plugins: [OFXImageEffectPlugin] {
    lock.locked { bundles.flatMap(\.plugins) + inProcessPlugins }
  }

  public func plugin(withIdentifier identifier: String) -> OFXImageEffectPlugin? {
    plugins.first { $0.identifier == identifier }
  }

  /// Loads one `.ofx.bundle`. Loading the same bundle twice returns the existing one.
  @discardableResult
  public func loadBundle(at url: URL) throws -> OFXPluginBundle {
    try lock.locked {
      let url = url.standardizedFileURL
      if let existing = bundles.first(where: { $0.url == url }) { return existing }
      let bundle = try OFXPluginBundle(url: url, host: self)
      bundles.append(bundle)
      return bundle
    }
  }

  /// Recursively finds and loads every `.ofx.bundle` in `directory`.
  ///
  /// - Returns: the bundles that loaded, and the errors for those that did not.
  @discardableResult
  public func loadPlugins(in directory: URL) -> (loaded: [OFXPluginBundle], failures: [(URL, Error)]) {
    var loaded: [OFXPluginBundle] = []
    var failures: [(URL, Error)] = []
    for url in Self.findBundles(in: directory) {
      do { loaded.append(try loadBundle(at: url)) } catch { failures.append((url, error)) }
    }
    return (loaded, failures)
  }

  /// Registers a plug-in that is linked into the current process rather than loaded from a bundle.
  @discardableResult
  public func register(plugin raw: UnsafeMutablePointer<OfxPlugin>) -> OFXImageEffectPlugin? {
    lock.locked {
      let api = raw.pointee.pluginApi.map { String(cString: $0) } ?? ""
      guard api == kOfxImageEffectPluginApi, raw.pointee.apiVersion == 1 else { return nil }
      let plugin = OFXImageEffectPlugin(raw: raw, bundle: nil, host: self)
      inProcessPlugins.append(plugin)
      return plugin
    }
  }

  /// Standard plug-in locations: `$OFX_PLUGIN_PATH` entries, then the platform default.
  public static var defaultPluginDirectories: [URL] {
    var dirs: [URL] = []
    if let env = ProcessInfo.processInfo.environment["OFX_PLUGIN_PATH"] {
      dirs += env.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
    }
    #if os(macOS)
    dirs.append(URL(fileURLWithPath: "/Library/OFX/Plugins"))
    #elseif os(Linux)
    dirs.append(URL(fileURLWithPath: "/usr/OFX/Plugins"))
    #endif
    return dirs
  }

  static func findBundles(in directory: URL) -> [URL] {
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

  // MARK: Messages

  func post(_ message: OFXMessage) -> OFXStatus { messageHandler(message) }

  // MARK: Host descriptor

  private func describeHost() {
    let p = properties
    let c = configuration
    p.set(kOfxPropType, kOfxTypeImageEffectHost)
    p.set(kOfxPropName, c.name)
    p.set(kOfxPropLabel, c.label)
    p.set(kOfxPropVersion, ints: [c.version.major, c.version.minor, c.version.micro])
    p.set(kOfxPropVersionLabel, "\(c.version.major).\(c.version.minor).\(c.version.micro)")
    p.set(kOfxPropAPIVersion, ints: [1, 5])
    p.set(kOfxPropHostOSHandle, pointer: nil)
    p.set(kOfxImageEffectHostPropIsBackground, c.isBackground)
    p.set(kOfxImageEffectHostPropNativeOrigin, kOfxHostNativeOriginBottomLeft)
    p.set(kOfxImageEffectPropSupportsOverlays, false)
    // Renders always happen at full resolution over the full frame.
    p.set(kOfxImageEffectPropSupportsMultiResolution, false)
    p.set(kOfxImageEffectPropSupportsTiles, false)
    p.set(kOfxImageEffectPropTemporalClipAccess, true)
    p.set(kOfxImageEffectPropSupportedComponents,
          strings: [kOfxImageComponentRGBA, kOfxImageComponentRGB, kOfxImageComponentAlpha])
    p.set(kOfxImageEffectPropSupportedContexts, strings: c.supportedContexts.map(\.rawValue))
    p.set(kOfxImageEffectPropSupportedPixelDepths, strings: [kOfxBitDepthByte, kOfxBitDepthShort, kOfxBitDepthFloat])
    p.set(kOfxImageEffectPropSupportsMultipleClipDepths, false)
    p.set(kOfxImageEffectPropSupportsMultipleClipPARs, false)
    p.set(kOfxImageEffectPropSetableFrameRate, false)
    p.set(kOfxImageEffectPropSetableFielding, false)
    p.set(kOfxImageEffectInstancePropSequentialRender, 0)
    p.set(kOfxImageEffectPropRenderQualityDraft, false)
    p.set(kOfxImageEffectPropOpenGLRenderSupported, "false")
    p.set(kOfxImageEffectPropMetalRenderSupported, "false")
    p.set(kOfxImageEffectPropColourManagementStyle, kOfxImageEffectColourManagementNone)
    p.set(kOfxParamHostPropSupportsCustomInteract, false)
    p.set(kOfxParamHostPropSupportsCustomAnimation, false)
    p.set(kOfxParamHostPropSupportsStringAnimation, false)
    p.set(kOfxParamHostPropSupportsChoiceAnimation, false)
    p.set(kOfxParamHostPropSupportsBooleanAnimation, false)
    p.set(kOfxParamHostPropSupportsStrChoice, true)
    p.set(kOfxParamHostPropSupportsStrChoiceAnimation, false)
    p.set(kOfxParamHostPropSupportsParametricAnimation, false)
    p.set(kOfxParamHostPropMaxParameters, -1)
    p.set(kOfxParamHostPropMaxPages, 0)
    p.set(kOfxParamHostPropPageRowColumnCount, ints: [0, 0])
  }
}

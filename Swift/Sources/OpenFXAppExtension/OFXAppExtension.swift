// Copyright OpenFX and contributors to the OpenFX project.
// SPDX-License-Identifier: BSD-3-Clause

import ExtensionFoundation
import Foundation
import OpenFXHost
import OpenFXRemote

/// The plug-in side of OpenFX over ExtensionKit: an app extension that vends
/// OpenFX plug-ins to a host app.
///
/// The extension is a small OpenFX host itself. Its plug-ins run in its process:
/// Swift plug-ins (`OpenFXPlugin`) and statically linked C/C++ plug-ins are
/// registered directly, and existing `.ofx.bundle`s can ship unmodified in the
/// extension's `Contents/PlugIns` folder (signed with it, so nothing is loaded
/// from outside the reviewed bundle).
///
/// ```swift
/// @main
/// struct MyEffectsExtension: OFXAppExtension {
///   @AppExtensionPoint.Bind
///   var extensionPoint: AppExtensionPoint {
///     AppExtensionPoint.Identifier(host: "com.example.editor", name: "OpenFXImageEffect")
///   }
///
///   func registerPlugins(in host: OFXHost) -> [String] {
///     for p in myRegistry.allPlugins { host.register(plugin: p) }
///     return OFXEmbeddedPlugins.load(into: host)
///   }
/// }
/// ```
@available(macOS 26.0, *)
public protocol OFXAppExtension: AppExtension where Configuration == ConnectionHandler {
  /// Registers or loads this extension's plug-ins into `host`. Called once per process.
  /// - Returns: descriptions of plug-ins that failed to load, reported to host apps.
  func registerPlugins(in host: OFXHost) -> [String]
}

@available(macOS 26.0, *)
extension OFXAppExtension {
  public var configuration: ConnectionHandler {
    let server = OFXExtensionServer.shared { host in registerPlugins(in: host) }
    return ConnectionHandler(onConnection: { connection in server.accept(connection) })
  }
}

/// The process-wide server: one OpenFX host per extension process, shared by all connections.
@available(macOS 26.0, *)
enum OFXExtensionServer {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var server: OFXRemoteServer?

  static func shared(_ register: (OFXHost) -> [String]) -> OFXRemoteServer {
    lock.withLock {
      if let server { return server }
      let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "OpenFX Extension"
      let host = OFXHost(configuration: .init(name: Bundle.main.bundleIdentifier ?? "org.openeffects.extension",
                                              label: name))
      let failures = register(host)
      let s = OFXRemoteServer(host: host, name: name)
      s.loadFailures = failures
      server = s
      return s
    }
  }
}

/// Loads `.ofx.bundle`s shipped inside the extension's own bundle.
public enum OFXEmbeddedPlugins {
  /// Loads every bundle in `directory` (default: the extension's `Contents/PlugIns`).
  /// - Returns: descriptions of bundles that failed to load.
  @discardableResult
  public static func load(into host: OFXHost, from directory: URL? = Bundle.main.builtInPlugInsURL) -> [String] {
    guard let directory, FileManager.default.fileExists(atPath: directory.path) else { return [] }
    return OFXPluginBundle.loadAll(in: directory, into: host).failures.map { "\($0.0.lastPathComponent): \($0.1)" }
  }
}

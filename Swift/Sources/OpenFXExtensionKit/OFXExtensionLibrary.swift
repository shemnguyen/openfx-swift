// Copyright OpenFX and contributors to the OpenFX project.
// SPDX-License-Identifier: BSD-3-Clause

import ExtensionFoundation
import Foundation
import Observation
import OpenFXRemote

/// The host-app side of OpenFX over ExtensionKit: finds the app extensions bound
/// to one of your extension points, launches them, and lists the effects they vend.
///
/// The app never loads plug-in code itself. Each extension runs in its own
/// sandboxed process (and can crash without taking the app down); effects are
/// used through `OFXRemoteEffect` / `OFXRemoteInstance`.
///
/// Define the extension point in your app target (Xcode generates the bundle
/// metadata when the target's `EX_ENABLE_EXTENSION_POINT_GENERATION` build
/// setting is `YES`):
///
/// ```swift
/// extension AppExtensionPoint {
///   @Definition
///   static var openFXImageEffect: AppExtensionPoint {
///     Name("OpenFXImageEffect")
///     UserInterface(false)
///     Scope(restriction: .none)   // allow extensions shipped in other developers' apps
///   }
/// }
///
/// let library = OFXExtensionLibrary()
/// try await library.start(extensionPoint: .openFXImageEffect)
/// // library.effects, library.unapprovedCount, ...
/// ```
///
/// Extensions shipped outside your app are disabled until the user enables them;
/// show `OFXExtensionBrowser` (or point them to System Settings) when
/// `unapprovedCount` or `disabledCount` is non-zero.
@available(macOS 26.0, *)
@MainActor
@Observable
public final class OFXExtensionLibrary {
  /// One enabled app extension and what it offers.
  public struct Extension: Identifiable {
    public var id: String { identity.id }
    public let identity: AppExtensionIdentity
    public let client: OFXRemoteClient
    public var effects: [OFXRemoteEffect] = []
    /// Plug-ins inside the extension that failed to load, or why the extension couldn't be used.
    public var problems: [String] = []
    public var isLoading = true
  }

  public private(set) var extensions: [Extension] = []
  /// Extensions installed but not yet approved by the user.
  public private(set) var unapprovedCount = 0
  /// Extensions the user turned off.
  public private(set) var disabledCount = 0
  /// Receives messages posted by plug-ins in any extension.
  public var onMessage: ((OFXRemoteMessage) -> Void)?

  /// All effects from all enabled extensions.
  public var effects: [OFXRemoteEffect] { extensions.flatMap(\.effects) }

  private var monitor: AppExtensionPoint.Monitor?

  public init() {}

  /// Starts monitoring an extension point; the lists update as extensions are
  /// installed, removed, enabled or disabled.
  public func start(extensionPoint: AppExtensionPoint) async throws {
    if let monitor {
      try await monitor.addAppExtensionPoint(extensionPoint)
    } else {
      monitor = try await AppExtensionPoint.Monitor(appExtensionPoint: extensionPoint)
      observe()
    }
  }

  /// Re-reads each extension's effects (e.g. after it was updated).
  public func reload() {
    for ext in extensions { load(ext.identity) }
  }

  private func observe() {
    guard let monitor else { return }
    let state = withObservationTracking {
      monitor.state
    } onChange: { [weak self] in
      Task { @MainActor in self?.observe() }
    }
    apply(state)
  }

  private func apply(_ state: AppExtensionPoint.Monitor.State) {
    unapprovedCount = state.unapprovedCount
    disabledCount = state.disabledCount
    let current = Set(state.identities.map(\.id))
    for ext in extensions where !current.contains(ext.id) { ext.client.disconnect() }
    extensions.removeAll { !current.contains($0.id) }
    for identity in state.identities where !extensions.contains(where: { $0.id == identity.id }) {
      let connector = ExtensionConnector(identity: identity)
      let client = OFXRemoteClient(name: identity.localizedName, connect: connector.connect)
      client.onMessage = { [weak self] message in
        Task { @MainActor in self?.onMessage?(message) }
      }
      extensions.append(Extension(identity: identity, client: client))
      load(identity)
    }
  }

  private func load(_ identity: AppExtensionIdentity) {
    guard let client = extensions.first(where: { $0.id == identity.id })?.client else { return }
    Task.detached {
      let result = Result { try client.loadEffects() }
      await MainActor.run { [weak self] in
        guard let self, let i = self.extensions.firstIndex(where: { $0.id == identity.id }) else { return }
        self.extensions[i].isLoading = false
        switch result {
        case .success(let (effects, failures)):
          self.extensions[i].effects = effects
          self.extensions[i].problems = failures
        case .failure(let error):
          self.extensions[i].effects = []
          self.extensions[i].problems = ["\(error)"]
        }
      }
    }
  }
}

/// Launches (and re-launches) one extension's process for `OFXRemoteClient`.
@available(macOS 26.0, *)
private final class ExtensionConnector: @unchecked Sendable {
  let identity: AppExtensionIdentity
  private let lock = NSLock()
  // Keep the process alive: the system invalidates the connection if it is released.
  private var process: AppExtensionProcess?

  init(identity: AppExtensionIdentity) { self.identity = identity }

  func connect() throws -> NSXPCConnection {
    try lock.withLock {
      process?.invalidate()
      let p = try AppExtensionProcess(configuration: .init(appExtensionIdentity: identity))
      process = p
      return try p.makeXPCConnection()
    }
  }

  deinit { process?.invalidate() }
}

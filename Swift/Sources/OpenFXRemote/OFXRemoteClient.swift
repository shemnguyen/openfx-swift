// Copyright OpenFX and contributors to the OpenFX project.
// SPDX-License-Identifier: BSD-3-Clause

import Foundation
import IOSurface
import OpenFXHost

/// A message a remote plug-in posted, as received by the host app.
public struct OFXRemoteMessage: CustomStringConvertible, Sendable {
  public var source: String
  public var type: OFXMessageType
  public var id: String?
  public var text: String
  public var isPersistent: Bool

  public var description: String {
    "OFX \(type.rawValue.replacingOccurrences(of: "OfxMessage", with: "")) [\(source)]: \(text)"
  }
}

/// The host app's connection to one plug-in process (e.g. one app extension).
///
/// The connection is made lazily, and made again after the process exits or
/// crashes; instances created through it re-create themselves on the new
/// connection (see `OFXRemoteInstance`).
///
/// Calls are synchronous and wait up to `timeout`, so make them off the main thread.
public final class OFXRemoteClient: @unchecked Sendable {
  /// A display name for the plug-in process (e.g. the extension's name).
  public let name: String
  /// How long to wait for any reply.
  public var timeout: TimeInterval = 30
  /// The contexts this host supports; plug-ins describe only these.
  public var supportedContexts: [OFXImageEffectContext] = [.filter, .general, .generator, .transition, .retimer]
  /// Receives messages posted by the remote plug-ins (on an arbitrary queue).
  public var onMessage: ((OFXRemoteMessage) -> Void)?
  /// Called (on an arbitrary queue) when the connection drops.
  public var onDisconnect: (() -> Void)?

  private let connectHandler: () throws -> NSXPCConnection
  private let lock = NSRecursiveLock()
  private var connection: NSXPCConnection?
  private var instances: [String: WeakInstance] = [:]
  private lazy var callbacks = HostCallbacks(client: self)
  /// Incremented each time a new connection is made.
  private(set) var generation = 0

  private struct WeakInstance { weak var value: OFXRemoteInstance? }

  /// - Parameter connect: makes a new, not yet resumed connection to the plug-in process,
  ///   e.g. `AppExtensionProcess.makeXPCConnection()`.
  public init(name: String, connect: @escaping () throws -> NSXPCConnection) {
    self.name = name
    self.connectHandler = connect
  }

  deinit { connection?.invalidate() }

  public func disconnect() {
    lock.locked {
      connection?.invalidate()
      connection = nil
    }
  }

  /// Fetches the plug-ins the process offers.
  public func loadEffects() throws -> (effects: [OFXRemoteEffect], failures: [String]) {
    let hello = OFXWire.Hello(protocolVersion: OFXWire.protocolVersion, contexts: supportedContexts.map(\.rawValue))
    let data = try call("hello") { proxy, done in proxy.hello(try OFXWire.encode(hello)) { done($0, nil, $1) } }.0
    let reply = try OFXWire.decode(OFXWire.HelloReply.self, data)
    guard reply.protocolVersion == OFXWire.protocolVersion else {
      throw OFXRemoteError.protocolMismatch(local: OFXWire.protocolVersion, remote: reply.protocolVersion)
    }
    return (reply.plugins.map { OFXRemoteEffect(client: self, wire: $0) }, reply.failures)
  }

  // MARK: Connection

  private func currentConnection() throws -> (NSXPCConnection, Int) {
    try lock.locked {
      if let connection { return (connection, generation) }
      let c: NSXPCConnection
      do { c = try connectHandler() } catch { throw OFXRemoteError.connectionFailed("\(error)") }
      c.remoteObjectInterface = OFXRemoteInterfaces.service
      c.exportedInterface = OFXRemoteInterfaces.host
      c.exportedObject = callbacks
      let id = ObjectIdentifier(c)
      let dropped: @Sendable () -> Void = { [weak self] in self?.connectionDropped(id) }
      c.interruptionHandler = dropped
      c.invalidationHandler = dropped
      generation += 1
      connection = c
      c.resume()
      return (c, generation)
    }
  }

  /// Connects if needed and returns the connection's generation.
  func connectedGeneration() throws -> Int { try currentConnection().1 }

  private func connectionDropped(_ id: ObjectIdentifier) {
    let wasCurrent = lock.locked { () -> Bool in
      guard connection.map(ObjectIdentifier.init) == id else { return false }
      connection = nil
      return true
    }
    if wasCurrent { onDisconnect?() }
  }

  /// Sends one request and waits for its reply.
  @discardableResult
  func call(_ what: String,
            _ send: (OFXRemoteServiceProtocol, @escaping (Data?, IOSurface?, NSError?) -> Void) throws -> Void)
    throws -> (Data?, IOSurface?)
  {
    let (connection, _) = try currentConnection()
    let done = DispatchSemaphore(value: 0)
    let resultLock = NSLock()
    var result: Result<(Data?, IOSurface?), Error>?
    let finish: (Result<(Data?, IOSurface?), Error>) -> Void = { r in
      resultLock.withLock { if result == nil { result = r; done.signal() } }
    }
    let proxy = connection.remoteObjectProxyWithErrorHandler { error in
      finish(.failure(OFXRemoteError.connectionFailed("\(error)")))
    }
    guard let service = proxy as? OFXRemoteServiceProtocol else { throw OFXRemoteError.badReply("proxy") }
    try send(service) { data, surface, error in
      finish(error.map { .failure(OFXRemoteErrorDomain.error(from: $0)) } ?? .success((data, surface)))
    }
    if done.wait(timeout: .now() + timeout) == .timedOut { throw OFXRemoteError.timedOut(what) }
    return try resultLock.withLock { result! }.get()
  }

  /// Fire-and-forget call (no reply).
  func send(_ body: (OFXRemoteServiceProtocol) -> Void) {
    guard let (connection, _) = try? currentConnection(),
          let service = connection.remoteObjectProxyWithErrorHandler({ _ in }) as? OFXRemoteServiceProtocol
    else { return }
    body(service)
  }

  func register(_ instance: OFXRemoteInstance, id: String) {
    lock.locked { instances[id] = WeakInstance(value: instance) }
  }

  func unregister(id: String) {
    lock.locked { instances[id] = nil }
  }

  fileprivate func instance(id: String?) -> OFXRemoteInstance? {
    guard let id else { return nil }
    return lock.locked { instances[id]?.value }
  }
}

/// Answers the plug-in process's requests: input frames and messages.
private final class HostCallbacks: NSObject, OFXRemoteHostProtocol, @unchecked Sendable {
  weak var client: OFXRemoteClient?
  init(client: OFXRemoteClient) { self.client = client }

  func frame(_ request: Data, reply: @escaping (Data?, IOSurface?) -> Void) {
    guard let req = try? OFXWire.decode(OFXWire.FrameRequest.self, request),
          let instance = client?.instance(id: req.instanceID),
          let buffer = try? instance.inputFrame(clip: req.clip, time: req.time),
          let (surface, frame) = OFXSurfaceFrames.makeSurface(from: buffer),
          let data = try? OFXWire.encode(frame)
    else { return reply(nil, nil) }
    reply(data, surface)
  }

  func message(_ message: Data) {
    guard let client, let m = try? OFXWire.decode(OFXWire.Message.self, message) else { return }
    let source = client.instance(id: m.instanceID)?.effect.label ?? client.name
    client.onMessage?(OFXRemoteMessage(source: source, type: OFXMessageType(rawValue: m.type), id: m.id,
                                       text: m.text, isPersistent: m.isPersistent))
  }
}

/// An image effect whose plug-in runs in another process.
public final class OFXRemoteEffect: OFXEffect, @unchecked Sendable {
  public let client: OFXRemoteClient
  let wire: OFXWire.Plugin
  /// The plug-in's global descriptor properties, mirrored from the plug-in process.
  public let properties: OFXPropertySet

  init(client: OFXRemoteClient, wire: OFXWire.Plugin) {
    self.client = client
    self.wire = wire
    self.properties = OFXWire.propertySet(wire.properties, debugName: "remote \(wire.identifier)")
  }

  public var identifier: String { wire.identifier }
  public var versionMajor: UInt32 { wire.versionMajor }
  public var versionMinor: UInt32 { wire.versionMinor }
  public var label: String {
    for key in [kOfxPropLabel, kOfxPropLongLabel, kOfxPropShortLabel] {
      if let s = properties.string(key), !s.isEmpty { return s }
    }
    return identifier
  }
  public var grouping: String { properties.string(kOfxImageEffectPluginPropGrouping) ?? "" }
  public var pluginDescription: String { properties.string(kOfxPropPluginDescription) ?? "" }
  public var supportedContexts: [OFXImageEffectContext] {
    properties.strings(kOfxImageEffectPropSupportedContexts).map(OFXImageEffectContext.init(rawValue:))
  }
  public var preferredContext: OFXImageEffectContext? {
    [.filter, .general, .generator, .transition, .retimer].first { wire.contexts[$0.rawValue] != nil }
  }
  public var origin: String { client.name }

  public func makeInstance(context: OFXImageEffectContext?, project: OFXProject,
                           preferredBitDepth: OFXBitDepth) throws -> any OFXEffectInstance {
    try makeRemoteInstance(context: context, project: project, preferredBitDepth: preferredBitDepth)
  }

  public func makeRemoteInstance(context: OFXImageEffectContext? = nil, project: OFXProject,
                                 preferredBitDepth: OFXBitDepth = .float) throws -> OFXRemoteInstance {
    guard let context = context ?? preferredContext, wire.contexts[context.rawValue] != nil else {
      throw OFXStatus.errUnsupported
    }
    return try OFXRemoteInstance(effect: self, context: context, project: project, preferredBitDepth: preferredBitDepth)
  }
}

/// An effect instance living in another process, with a local mirror of its parameters.
///
/// Parameter values are mirrored locally, so reading them never crosses processes.
/// If the plug-in process exits or crashes, the next call re-creates the instance
/// on a new connection and replays its parameters, inputs and time.
public final class OFXRemoteInstance: OFXEffectInstance, @unchecked Sendable {
  public let effect: OFXRemoteEffect
  public let context: OFXImageEffectContext
  public let project: OFXProject
  public let preferredBitDepth: OFXBitDepth
  public let parameterSet: OFXParameterSet
  public private(set) var inputClipNames: [String] = []
  public var onParameterChangedByPlugin: ((OFXParameter) -> Void)?

  public var abortRequested: Bool {
    get { lock.locked { _abort } }
    set {
      lock.locked { _abort = newValue }
      if newValue, let id = lock.locked({ remoteID }) { client.send { $0.abort(id) } }
    }
  }

  private var client: OFXRemoteClient { effect.client }
  private let lock = NSRecursiveLock()
  private let callLock = NSLock()
  private var remoteID: String?
  private var remoteGeneration = -1
  private var sources: [String: OFXClipSource] = [:]
  private var time: Double
  private var _abort = false

  init(effect: OFXRemoteEffect, context: OFXImageEffectContext, project: OFXProject,
       preferredBitDepth: OFXBitDepth) throws {
    self.effect = effect
    self.context = context
    self.project = project
    self.preferredBitDepth = preferredBitDepth
    self.time = project.frameRange.lowerBound
    var timeRef: (() -> Double?)?
    self.parameterSet = OFXParameterSet(currentTime: { timeRef?() })
    timeRef = { [weak self] in self?.lock.locked { self?.time } }
    _ = try callLock.withLock { try ensureRemote() }
  }

  deinit {
    if let id = remoteID {
      client.unregister(id: id)
      client.send { $0.destroyInstance(id) }
    }
  }

  public var parameters: [OFXParameter] { parameterSet.parameters }
  public func parameter(named name: String) -> OFXParameter? { parameterSet[name] }

  // MARK: OFXEffectInstance

  public func setInput(_ clipName: String, source: OFXClipSource?) throws {
    try callLock.withLock {
      guard inputClipNames.contains(clipName) else { throw OFXStatus.errUnknown }
      lock.locked { sources[clipName] = source }
      try edit([.connectInput(clip: clipName, connected: source != nil)])
    }
  }

  public func setValue(_ value: OFXParameterValue, for name: String, at time: Double?) throws {
    try callLock.withLock {
      guard let param = parameter(named: name) else { throw OFXStatus.errUnknown }
      param.setValue(value, at: time)
      try edit([.setValue(name: name, value: OFXWire.ParamValue(value), time: time)])
    }
  }

  public func pressButton(_ name: String) throws {
    try callLock.withLock { try edit([.pressButton(name: name)]) }
  }

  public func setTime(_ time: Double) {
    lock.locked { self.time = time }
    try? callLock.withLock { try edit([.setTime(time)]) }
  }

  public func render(time: Double, interactive: Bool = false,
                     cropToRegionOfDefinition: Bool = false) throws -> OFXImageBuffer {
    try callLock.withLock {
      lock.locked { self.time = time; _abort = false }
      return try retryingOnce {
        let id = try ensureRemote()
        let req = OFXWire.Render(instanceID: id, time: time, interactive: interactive,
                                 cropToRegionOfDefinition: cropToRegionOfDefinition)
        let (data, surface) = try client.call("render") { proxy, done in proxy.render(try OFXWire.encode(req), reply: done) }
        guard let surface else { throw OFXRemoteError.badReply("render returned no surface") }
        return try OFXSurfaceFrames.buffer(from: surface, frame: try OFXWire.decode(OFXWire.Frame.self, data),
                                           readOnly: false)
      }
    }
  }

  // MARK: Plumbing

  /// Serves a frame request from the plug-in process.
  func inputFrame(clip: String, time: Double) throws -> OFXImageBuffer? {
    guard let source = lock.locked({ sources[clip] }) else { return nil }
    return try source(time)
  }

  private func edit(_ edits: [OFXWire.Edit]) throws {
    try retryingOnce {
      let id = try ensureRemote()
      let req = OFXWire.EditRequest(instanceID: id, edits: edits)
      let data = try client.call("edit") { proxy, done in proxy.edit(try OFXWire.encode(req)) { done($0, nil, $1) } }.0
      apply(try OFXWire.decode(OFXWire.EditReply.self, data))
    }
  }

  private func apply(_ reply: OFXWire.EditReply) {
    for state in reply.changedByPlugin {
      guard let p = parameter(named: state.name) else { continue }
      state.apply(to: p)
      onParameterChangedByPlugin?(p)
    }
  }

  /// Retries once after a dropped connection, which re-creates the instance.
  private func retryingOnce<T>(_ body: () throws -> T) throws -> T {
    do { return try body() } catch OFXRemoteError.connectionFailed(_), OFXRemoteError.connectionInterrupted {
      client.disconnect()
      return try body()
    }
  }

  /// Returns the remote instance ID, creating (or re-creating) the remote instance if needed.
  @discardableResult
  private func ensureRemote() throws -> String {
    let generation = try client.connectedGeneration()
    if let id = remoteID, remoteGeneration == generation { return id }
    let create = OFXWire.CreateInstance(pluginID: effect.identifier, context: context.rawValue,
                                        project: OFXWire.Project(project), preferredBitDepth: preferredBitDepth.rawValue)
    let data = try client.call("createInstance") { proxy, done in
      proxy.createInstance(try OFXWire.encode(create)) { done($0, nil, $1) }
    }.0
    let created = try OFXWire.decode(OFXWire.InstanceCreated.self, data)
    if let old = remoteID { client.unregister(id: old) }
    let isFirst = remoteID == nil
    remoteID = created.instanceID
    remoteGeneration = generation
    client.register(self, id: created.instanceID)

    if isFirst {
      // Build the local parameter mirror from the instance's parameters.
      inputClipNames = created.inputClipNames
      for p in created.params {
        let param = parameterSet.addParameter(name: p.name, type: OFXParamType(rawValue: p.type),
                                              properties: OFXWire.propertySet(p.properties, debugName: "param \(p.name)"))
        created.paramStates.first { $0.name == p.name }?.apply(to: param)
      }
    } else {
      // The plug-in process restarted: replay our state into the new instance.
      var edits: [OFXWire.Edit] = [.restore(parameters.map(OFXWire.ParamState.init))]
      edits += lock.locked { sources.keys.map { OFXWire.Edit.connectInput(clip: $0, connected: true) } }
      edits.append(.setTime(lock.locked { time }))
      let req = OFXWire.EditRequest(instanceID: created.instanceID, edits: edits)
      _ = try client.call("restore") { proxy, done in proxy.edit(try OFXWire.encode(req)) { done($0, nil, $1) } }
    }
    return created.instanceID
  }
}

extension NSRecursiveLock {
  @inline(__always)
  func locked<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}

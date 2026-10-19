// Copyright OpenFX and contributors to the OpenFX project.
// SPDX-License-Identifier: BSD-3-Clause

import Foundation
import IOSurface
import OpenFXHost

/// Serves the plug-ins of an in-process `OFXHost` to host apps over XPC.
///
/// This runs on the plug-in side, e.g. inside an app extension. The plug-ins
/// themselves are ordinary OpenFX plug-ins: registered in-process
/// (`host.register(plugin:)`, for Swift or statically linked C/C++ plug-ins) or
/// loaded from `.ofx.bundle`s shipped inside the extension's own bundle.
///
/// ```swift
/// let host = OFXHost()
/// for p in myRegistry.allPlugins { host.register(plugin: p) }
/// let server = OFXRemoteServer(host: host)
/// // in the XPC listener / AppExtension connection handler:
/// server.accept(connection)
/// ```
public final class OFXRemoteServer: @unchecked Sendable {
  public let host: OFXHost
  public let name: String
  /// Problems found while loading plug-ins, reported to host apps in `hello`.
  public var loadFailures: [String] = []

  private let lock = NSLock()
  private var sessions: [ObjectIdentifier: OFXRemoteSession] = [:]

  public init(host: OFXHost, name: String = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName) {
    self.host = host
    self.name = name
    host.messageHandler = { [weak self] message in
      self?.route(message) ?? .ok
    }
  }

  /// Configures and resumes an incoming connection from a host app.
  @discardableResult
  public func accept(_ connection: NSXPCConnection) -> Bool {
    let session = OFXRemoteSession(server: self, connection: connection)
    connection.exportedInterface = OFXRemoteInterfaces.service
    connection.exportedObject = session
    connection.remoteObjectInterface = OFXRemoteInterfaces.host
    let id = ObjectIdentifier(session)
    let close: @Sendable () -> Void = { [weak self] in
      guard let self else { return }
      let s = self.lock.withLock { self.sessions.removeValue(forKey: id) }
      s?.close()
    }
    connection.invalidationHandler = close
    connection.interruptionHandler = close
    lock.withLock { sessions[id] = session }
    connection.resume()
    return true
  }

  /// Forwards a plug-in message to the host app that owns the posting instance.
  private func route(_ message: OFXMessage) -> OFXStatus {
    let all = lock.withLock { Array(sessions.values) }
    let owner = message.effect.flatMap { effect in all.lazy.compactMap { $0.instanceID(of: effect).map { ($0, $1) } }.first }
    let wire = OFXWire.Message(instanceID: owner?.1, type: message.type.rawValue, id: message.id,
                               text: message.text, isPersistent: message.isPersistent)
    for session in owner.map({ [$0.0] }) ?? all { session.post(wire) }
    return message.type == .question ? .replyYes : .ok
  }
}

/// One host app connection: its instances and the calls it makes.
final class OFXRemoteSession: NSObject, OFXRemoteServiceProtocol, @unchecked Sendable {
  private weak var server: OFXRemoteServer?
  private weak var connection: NSXPCConnection?

  /// A remote instance and the queue its work is serialised on, so slow renders
  /// never block the XPC connection (abort must get through while rendering).
  private final class Entry {
    let instance: OFXImageEffectInstance
    let queue: DispatchQueue
    var changedByPlugin: [String] = []
    init(_ instance: OFXImageEffectInstance, id: String) {
      self.instance = instance
      self.queue = DispatchQueue(label: "openfx.remote.instance.\(id)", qos: .userInitiated)
    }
  }

  private let lock = NSLock()
  private var entries: [String: Entry] = [:]

  init(server: OFXRemoteServer, connection: NSXPCConnection) {
    self.server = server
    self.connection = connection
  }

  func close() {
    lock.withLock { entries.removeAll() }
  }

  func instanceID(of effect: OFXImageEffect) -> (OFXRemoteSession, String)? {
    lock.withLock {
      entries.first { $0.value.instance === effect }.map { (self, $0.key) }
    }
  }

  func post(_ message: OFXWire.Message) {
    guard let data = try? OFXWire.encode(message) else { return }
    (connection?.remoteObjectProxy as? OFXRemoteHostProtocol)?.message(data)
  }

  private func entry(_ id: String) throws -> Entry {
    guard let e = lock.withLock({ entries[id] }) else { throw OFXRemoteError.unknownInstance(id) }
    return e
  }

  // MARK: OFXRemoteServiceProtocol

  func hello(_ request: Data, reply: @escaping (Data?, NSError?) -> Void) {
    do {
      guard let server else { throw OFXRemoteError.connectionInterrupted }
      let hello = try OFXWire.decode(OFXWire.Hello.self, request)
      var failures = server.loadFailures
      var plugins: [OFXWire.Plugin] = []
      for plugin in server.host.plugins {
        do {
          let main = try plugin.describe()
          var contexts: [String: OFXWire.Descriptor] = [:]
          for context in main.supportedContexts where hello.contexts.contains(context.rawValue) {
            guard let d = try? plugin.descriptor(for: context) else { continue }
            contexts[context.rawValue] = OFXWire.Descriptor(
              properties: OFXWire.properties(d.properties),
              clips: d.clips.map { OFXWire.Clip(name: $0.name, properties: OFXWire.properties($0.properties)) },
              params: d.parameters.map { Self.wireParam($0) })
          }
          plugins.append(OFXWire.Plugin(identifier: plugin.identifier, versionMajor: plugin.versionMajor,
                                        versionMinor: plugin.versionMinor,
                                        properties: OFXWire.properties(main.properties), contexts: contexts))
        } catch {
          failures.append("\(plugin.identifier): \(error)")
        }
      }
      reply(try OFXWire.encode(OFXWire.HelloReply(protocolVersion: OFXWire.protocolVersion, serverName: server.name,
                                                  plugins: plugins, failures: failures)), nil)
    } catch {
      reply(nil, OFXRemoteErrorDomain.nsError(error))
    }
  }

  func createInstance(_ request: Data, reply: @escaping (Data?, NSError?) -> Void) {
    do {
      guard let server else { throw OFXRemoteError.connectionInterrupted }
      let req = try OFXWire.decode(OFXWire.CreateInstance.self, request)
      guard let plugin = server.host.plugin(withIdentifier: req.pluginID) else { throw OFXStatus.errUnknown }
      let instance = try plugin.createInstance(context: OFXImageEffectContext(rawValue: req.context),
                                               project: req.project.project,
                                               preferredBitDepth: OFXBitDepth(rawValue: req.preferredBitDepth))
      let id = UUID().uuidString
      let entry = Entry(instance, id: id)
      instance.onParameterChangedByPlugin = { [weak entry] param in entry?.changedByPlugin.append(param.name) }
      lock.withLock { entries[id] = entry }
      reply(try OFXWire.encode(OFXWire.InstanceCreated(
        instanceID: id, context: instance.context.rawValue, inputClipNames: instance.inputClipNames,
        params: instance.parameters.map { Self.wireParam($0) },
        paramStates: instance.parameters.map(OFXWire.ParamState.init))), nil)
    } catch {
      reply(nil, OFXRemoteErrorDomain.nsError(error))
    }
  }

  func destroyInstance(_ instanceID: String) {
    guard let e = lock.withLock({ entries.removeValue(forKey: instanceID) }) else { return }
    // Let queued work finish; the instance is destroyed when the last reference goes.
    e.queue.async { _ = e }
  }

  func edit(_ request: Data, reply: @escaping (Data?, NSError?) -> Void) {
    do {
      let req = try OFXWire.decode(OFXWire.EditRequest.self, request)
      let e = try entry(req.instanceID)
      e.queue.async { [weak self] in
        do {
          e.changedByPlugin.removeAll()
          for edit in req.edits { try self?.apply(edit, to: e, instanceID: req.instanceID) }
          let names = Array(Set(e.changedByPlugin))
          let changed = names.compactMap { e.instance.parameter(named: $0) }.map(OFXWire.ParamState.init)
          reply(try OFXWire.encode(OFXWire.EditReply(changedByPlugin: changed)), nil)
        } catch {
          reply(nil, OFXRemoteErrorDomain.nsError(error))
        }
      }
    } catch {
      reply(nil, OFXRemoteErrorDomain.nsError(error))
    }
  }

  private func apply(_ edit: OFXWire.Edit, to e: Entry, instanceID: String) throws {
    let instance = e.instance
    switch edit {
    case .setValue(let name, let value, let time):
      try instance.setValue(value.value, for: name, at: time)
    case .pressButton(let name):
      try instance.pressButton(name)
    case .setTime(let t):
      instance.setTime(t)
    case .connectInput(let clip, let connected):
      try instance.setInput(clip, source: connected ? { [weak self] time in
        try self?.fetchFrame(instanceID: instanceID, clip: clip, time: time)
      } : nil)
    case .restore(let states):
      for s in states { if let p = instance.parameter(named: s.name) { s.apply(to: p) } }
    }
  }

  func render(_ request: Data, reply: @escaping (Data?, IOSurface?, NSError?) -> Void) {
    do {
      let req = try OFXWire.decode(OFXWire.Render.self, request)
      let e = try entry(req.instanceID)
      e.queue.async {
        do {
          let output = try e.instance.render(time: req.time, interactive: req.interactive,
                                             cropToRegionOfDefinition: req.cropToRegionOfDefinition)
          guard let (surface, frame) = OFXSurfaceFrames.makeSurface(from: output) else {
            throw OFXStatus.failed
          }
          reply(try OFXWire.encode(frame), surface, nil)
        } catch {
          reply(nil, nil, OFXRemoteErrorDomain.nsError(error))
        }
      }
    } catch {
      reply(nil, nil, OFXRemoteErrorDomain.nsError(error))
    }
  }

  func abort(_ instanceID: String) {
    (try? entry(instanceID))?.instance.abortRequested = true
  }

  // MARK: Frames from the host app

  /// Called from inside a render when the plug-in fetches an input image: asks the
  /// host app for the frame, synchronously.
  private func fetchFrame(instanceID: String, clip: String, time: Double) throws -> OFXImageBuffer? {
    guard let connection else { throw OFXRemoteError.connectionInterrupted }
    var failure: Error?
    var result: (Data?, IOSurface?) = (nil, nil)
    let proxy = connection.synchronousRemoteObjectProxyWithErrorHandler { failure = $0 } as? OFXRemoteHostProtocol
    let request = try OFXWire.encode(OFXWire.FrameRequest(instanceID: instanceID, clip: clip, time: time))
    proxy?.frame(request) { result = ($0, $1) }
    if let failure { throw OFXRemoteError.connectionFailed("\(failure)") }
    guard let data = result.0, let surface = result.1 else { return nil }
    return try OFXSurfaceFrames.buffer(from: surface, frame: try OFXWire.decode(OFXWire.Frame.self, data), readOnly: true)
  }

  static func wireParam(_ p: OFXParameter) -> OFXWire.Param {
    OFXWire.Param(name: p.name, type: p.type.rawValue, properties: OFXWire.properties(p.properties))
  }
}

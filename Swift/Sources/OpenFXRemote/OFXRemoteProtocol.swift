// Copyright OpenFX and contributors to the OpenFX project.
// SPDX-License-Identifier: BSD-3-Clause

import Foundation
import IOSurface
import OpenFXHost

// The XPC protocol between a host app and a process that runs OpenFX plug-ins
// (an app extension, or any XPC peer).
//
// OpenFX itself is an in-process C API: plug-ins call back into the host's
// suites hundreds of times per frame, and images are shared by pointer. So the
// plug-ins don't talk to the app directly. They run inside an OpenFX host
// *in the extension process* (OpenFXHost), and only coarse operations cross the
// process boundary:
//
//   app -> extension   describe, create/destroy instance, edit parameters,
//                      connect inputs, render, abort
//   extension -> app   fetch an input frame (clip, time), post a message
//
// Frames travel as IOSurfaces (shared memory, no copies through XPC); every
// other payload is a property-list encoded `OFXWire` value.

/// Implemented by the plug-in side (`OFXRemoteServer`).
@objc(OFXRemoteServiceProtocol)
public protocol OFXRemoteServiceProtocol {
  /// `OFXWire.Hello` -> `OFXWire.HelloReply`: the plug-ins and their descriptions.
  func hello(_ request: Data, reply: @escaping (Data?, NSError?) -> Void)
  /// `OFXWire.CreateInstance` -> `OFXWire.InstanceCreated`.
  func createInstance(_ request: Data, reply: @escaping (Data?, NSError?) -> Void)
  func destroyInstance(_ instanceID: String)
  /// `OFXWire.EditRequest` -> `OFXWire.EditReply`.
  func edit(_ request: Data, reply: @escaping (Data?, NSError?) -> Void)
  /// `OFXWire.Render` -> `OFXWire.Frame` describing the returned surface.
  func render(_ request: Data, reply: @escaping (Data?, IOSurface?, NSError?) -> Void)
  /// Asks the plug-in to abandon the instance's current render.
  func abort(_ instanceID: String)
}

/// Implemented by the host app side (`OFXRemoteClient`).
@objc(OFXRemoteHostProtocol)
public protocol OFXRemoteHostProtocol {
  /// `OFXWire.FrameRequest` -> `OFXWire.Frame` and its surface, or nils when there is no frame.
  func frame(_ request: Data, reply: @escaping (Data?, IOSurface?) -> Void)
  /// An `OFXWire.Message` posted by a plug-in.
  func message(_ message: Data)
}

enum OFXRemoteInterfaces {
  static var service: NSXPCInterface { NSXPCInterface(with: OFXRemoteServiceProtocol.self) }
  static var host: NSXPCInterface { NSXPCInterface(with: OFXRemoteHostProtocol.self) }
}

/// Errors from talking to a remote plug-in process. Plug-in failures arrive as `OFXStatus`.
public enum OFXRemoteError: Error, CustomStringConvertible {
  case connectionFailed(String)
  case connectionInterrupted
  case timedOut(String)
  case protocolMismatch(local: Int, remote: Int)
  case unknownInstance(String)
  case remote(String)
  case badReply(String)

  public var description: String {
    switch self {
    case .connectionFailed(let s): return "could not connect to the plug-in process: \(s)"
    case .connectionInterrupted: return "the plug-in process exited or the connection was interrupted"
    case .timedOut(let s): return "the plug-in process did not answer \(s) in time"
    case .protocolMismatch(let l, let r): return "plug-in process speaks protocol \(r), this host speaks \(l)"
    case .unknownInstance(let id): return "unknown effect instance \(id)"
    case .remote(let s): return s
    case .badReply(let s): return "malformed reply: \(s)"
    }
  }
}

/// Error domains used to carry failures across XPC as `NSError`s.
enum OFXRemoteErrorDomain {
  static let status = "org.openeffects.status"
  static let remote = "org.openeffects.remote"

  static func nsError(_ error: Error) -> NSError {
    if let status = error as? OFXStatus {
      return NSError(domain: Self.status, code: Int(status.rawValue),
                     userInfo: [NSLocalizedDescriptionKey: status.name])
    }
    return NSError(domain: remote, code: 1, userInfo: [NSLocalizedDescriptionKey: "\(error)"])
  }

  static func error(from ns: NSError) -> Error {
    if ns.domain == status { return OFXStatus(OfxStatus(ns.code)) }
    if ns.domain == remote { return OFXRemoteError.remote(ns.localizedDescription) }
    return OFXRemoteError.connectionFailed(ns.localizedDescription)
  }
}

/// The values exchanged over XPC, property-list encoded.
public enum OFXWire {
  /// Bumped on incompatible changes to the messages below.
  public static let protocolVersion = 1

  static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    return try encoder.encode(value)
  }

  static func decode<T: Decodable>(_ type: T.Type, _ data: Data?) throws -> T {
    guard let data else { throw OFXRemoteError.badReply("missing \(T.self)") }
    do { return try PropertyListDecoder().decode(type, from: data) } catch {
      throw OFXRemoteError.badReply("\(T.self): \(error)")
    }
  }

  // MARK: Properties

  /// A property value. Pointer properties are process-local and never sent.
  public enum Value: Codable, Equatable {
    case int([Int])
    case double([Double])
    case string([String])
  }

  public typealias Properties = [String: Value]

  static func properties(_ set: OFXPropertySet) -> Properties {
    var out: Properties = [:]
    for name in set.names {
      switch set[name] {
      case .int(let v)?: out[name] = .int(v)
      case .double(let v)?: out[name] = .double(v)
      case .string(let v)?: out[name] = .string(v)
      default: break
      }
    }
    return out
  }

  static func propertySet(_ props: Properties, debugName: String) -> OFXPropertySet {
    let set = OFXPropertySet(debugName: debugName)
    for (name, value) in props {
      switch value {
      case .int(let v): set[name] = .int(v)
      case .double(let v): set[name] = .double(v)
      case .string(let v): set[name] = .string(v)
      }
    }
    return set
  }

  // MARK: Description

  public struct Clip: Codable {
    public var name: String
    public var properties: Properties
  }

  public struct Param: Codable {
    public var name: String
    public var type: String
    public var properties: Properties
  }

  /// A context descriptor: the clips and parameters the plug-in defines in one context.
  public struct Descriptor: Codable {
    public var properties: Properties
    public var clips: [Clip]
    public var params: [Param]
  }

  public struct Plugin: Codable {
    public var identifier: String
    public var versionMajor: UInt32
    public var versionMinor: UInt32
    /// The global descriptor (label, grouping, supported contexts and depths, ...).
    public var properties: Properties
    /// Descriptors for each context both sides support, keyed by context name.
    public var contexts: [String: Descriptor]
  }

  public struct Hello: Codable {
    public var protocolVersion: Int
    /// The contexts the host app supports; only these are described.
    public var contexts: [String]
  }

  public struct HelloReply: Codable {
    public var protocolVersion: Int
    public var serverName: String
    public var plugins: [Plugin]
    /// Plug-ins (or bundles) that failed to load or describe, for diagnostics.
    public var failures: [String]
  }

  // MARK: Instances

  public struct Project: Codable {
    public var width: Int
    public var height: Int
    public var pixelAspectRatio: Double
    public var frameRate: Double
    public var firstFrame: Double
    public var lastFrame: Double

    init(_ p: OFXProject) {
      width = p.width; height = p.height; pixelAspectRatio = p.pixelAspectRatio
      frameRate = p.frameRate; firstFrame = p.frameRange.lowerBound; lastFrame = p.frameRange.upperBound
    }

    var project: OFXProject {
      OFXProject(width: width, height: height, pixelAspectRatio: pixelAspectRatio, frameRate: frameRate,
                 frameRange: firstFrame...max(firstFrame, lastFrame))
    }
  }

  public enum ParamValue: Codable, Equatable {
    case none
    case int([Int])
    case double([Double])
    case string(String)

    init(_ v: OFXParameterValue) {
      switch v {
      case .none: self = .none
      case .int(let a): self = .int(a)
      case .double(let a): self = .double(a)
      case .string(let s): self = .string(s)
      }
    }

    var value: OFXParameterValue {
      switch self {
      case .none: return .none
      case .int(let a): return .int(a)
      case .double(let a): return .double(a)
      case .string(let s): return .string(s)
      }
    }
  }

  public struct Keyframe: Codable {
    public var time: Double
    public var value: ParamValue
  }

  /// Everything about a parameter's value: its static value and keyframes.
  public struct ParamState: Codable {
    public var name: String
    public var value: ParamValue
    public var keyframes: [Keyframe]

    init(_ p: OFXParameter) {
      name = p.name
      value = ParamValue(p.staticValue)
      keyframes = p.keyframes.map { Keyframe(time: $0.time, value: ParamValue($0.value)) }
    }

    func apply(to p: OFXParameter) {
      p.restore(staticValue: value.value, keyframes: keyframes.map { ($0.time, $0.value.value) })
    }
  }

  public struct CreateInstance: Codable {
    public var pluginID: String
    public var context: String
    public var project: Project
    public var preferredBitDepth: String
  }

  public struct InstanceCreated: Codable {
    public var instanceID: String
    public var context: String
    public var inputClipNames: [String]
    /// The instance's parameters (properties and initial values, after any normalised defaults).
    public var params: [Param]
    public var paramStates: [ParamState]
  }

  public enum Edit: Codable {
    case setValue(name: String, value: ParamValue, time: Double?)
    case pressButton(name: String)
    case setTime(Double)
    case connectInput(clip: String, connected: Bool)
    /// Restores parameter state wholesale (used when re-creating an instance after a crash).
    case restore([ParamState])
  }

  public struct EditRequest: Codable {
    public var instanceID: String
    public var edits: [Edit]
  }

  public struct EditReply: Codable {
    /// Parameters the plug-in changed itself while handling the edits.
    public var changedByPlugin: [ParamState]
  }

  public struct Render: Codable {
    public var instanceID: String
    public var time: Double
    public var interactive: Bool
    public var cropToRegionOfDefinition: Bool
  }

  // MARK: Frames and messages

  /// Describes the pixels in an accompanying IOSurface (rows bottom-up, OpenFX order).
  public struct Frame: Codable {
    public var bounds: [Int32]
    public var bitDepth: String
    public var components: String
    public var premultiplication: String
    public var pixelAspectRatio: Double
  }

  public struct FrameRequest: Codable {
    public var instanceID: String
    public var clip: String
    public var time: Double
  }

  public struct Message: Codable {
    public var instanceID: String?
    public var type: String
    public var id: String?
    public var text: String
    public var isPersistent: Bool
  }
}

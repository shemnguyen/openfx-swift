// Copyright OpenFX and contributors to the OpenFX project.
// SPDX-License-Identifier: BSD-3-Clause

import Foundation
import OpenFX

/// Exposes Swift `OFXEffectPlugin` types through the OpenFX C entry points.
///
/// A plug-in binary (a dynamic library packaged as `Name.ofx.bundle`) creates
/// one registry and exports the two required C symbols from it:
///
/// ```swift
/// import OpenFXPlugin
///
/// let registry = OFXPluginRegistry([Gain.self, Invert.self])
///
/// @_cdecl("OfxGetNumberOfPlugins")
/// public func OfxGetNumberOfPlugins() -> Int32 { registry.count }
///
/// @_cdecl("OfxGetPlugin")
/// public func OfxGetPlugin(_ nth: Int32) -> UnsafeMutablePointer<OfxPlugin>? { registry.plugin(at: nth) }
/// ```
///
/// The same registry can be handed to an in-process `OFXHost` with
/// `host.register(plugin:)`, which is how the package's tests run plug-ins.
public final class OFXPluginRegistry {
  private let plugins: [UnsafeMutablePointer<OfxPlugin>]

  public init(_ types: [any OFXEffectPlugin.Type]) {
    plugins = types.compactMap { Slots.claim($0) }
  }

  public var count: Int32 { Int32(plugins.count) }

  public func plugin(at nth: Int32) -> UnsafeMutablePointer<OfxPlugin>? {
    nth >= 0 && Int(nth) < plugins.count ? plugins[Int(nth)] : nil
  }

  public var allPlugins: [UnsafeMutablePointer<OfxPlugin>] { plugins }
}

/// OpenFX identifies a plug-in only by which `mainEntry` function the host
/// calls, and Swift cannot mint new C function pointers at run time. So there
/// is a fixed table of entry points, each bound to one slot.
enum Slots {
  static let capacity = 16

  private static let lock = NSLock()
  private static var types: [(any OFXEffectPlugin.Type)?] = Array(repeating: nil, count: capacity)
  private static var used = 0

  static func claim(_ type: any OFXEffectPlugin.Type) -> UnsafeMutablePointer<OfxPlugin>? {
    lock.lock()
    defer { lock.unlock() }
    guard used < capacity else {
      FileHandle.standardError.write("OpenFXPlugin: more than \(capacity) plug-ins in one binary; \(type.identifier) not exported\n".data(using: .utf8)!)
      return nil
    }
    let slot = used
    used += 1
    types[slot] = type
    let p = UnsafeMutablePointer<OfxPlugin>.allocate(capacity: 1)
    p.initialize(to: OfxPlugin(
      pluginApi: UnsafePointer(strdup(kOfxImageEffectPluginApi)),
      apiVersion: 1,
      pluginIdentifier: UnsafePointer(strdup(type.identifier)),
      pluginVersionMajor: type.versionMajor,
      pluginVersionMinor: type.versionMinor,
      setHost: { host in
        guard let host else { return }
        OFXHostConnection.current = OFXHostConnection(host: host)
      },
      mainEntry: entryPoints[slot]))
    return p
  }

  static func type(at slot: Int) -> (any OFXEffectPlugin.Type)? {
    lock.lock()
    defer { lock.unlock() }
    return types[slot]
  }

  // One C entry point per slot; each forwards to `Dispatch.main` with its slot number.
  typealias EntryPoint = @convention(c) (UnsafePointer<CChar>?, UnsafeRawPointer?,
                                         OfxPropertySetHandle?, OfxPropertySetHandle?) -> OfxStatus

  static let entryPoints: [EntryPoint] = [
    { Dispatch.main(0, $0, $1, $2, $3) }, { Dispatch.main(1, $0, $1, $2, $3) },
    { Dispatch.main(2, $0, $1, $2, $3) }, { Dispatch.main(3, $0, $1, $2, $3) },
    { Dispatch.main(4, $0, $1, $2, $3) }, { Dispatch.main(5, $0, $1, $2, $3) },
    { Dispatch.main(6, $0, $1, $2, $3) }, { Dispatch.main(7, $0, $1, $2, $3) },
    { Dispatch.main(8, $0, $1, $2, $3) }, { Dispatch.main(9, $0, $1, $2, $3) },
    { Dispatch.main(10, $0, $1, $2, $3) }, { Dispatch.main(11, $0, $1, $2, $3) },
    { Dispatch.main(12, $0, $1, $2, $3) }, { Dispatch.main(13, $0, $1, $2, $3) },
    { Dispatch.main(14, $0, $1, $2, $3) }, { Dispatch.main(15, $0, $1, $2, $3) },
  ]
}

/// Translates OpenFX actions into `OFXEffectPlugin` calls.
enum Dispatch {
  static func main(_ slot: Int, _ cAction: UnsafePointer<CChar>?, _ handle: UnsafeRawPointer?,
                   _ inArgs: OfxPropertySetHandle?, _ outArgs: OfxPropertySetHandle?) -> OfxStatus {
    guard let type = Slots.type(at: slot), let cAction else { return kOfxStatErrFatal }
    guard let connection = OFXHostConnection.current else { return kOfxStatErrMissingHostFeature }
    let action = OFXAction(rawValue: String(cString: cAction))
    let effect = handle.map { OFXEffectRef(OpaquePointer($0), connection: connection) }
    let inProps = inArgs.map { connection.properties($0) }
    let outProps = outArgs.map { connection.properties($0) }

    do {
      switch action {
      case .load, .unload:
        return kOfxStatOK

      case .describe:
        guard let effect else { return kOfxStatErrBadHandle }
        try type.describe(effect)
        return kOfxStatOK

      case .describeInContext:
        guard let effect, let inProps else { return kOfxStatErrBadHandle }
        let context = OFXImageEffectContext(rawValue: try inProps.string(kOfxImageEffectPropContext))
        try type.describeInContext(effect, context: context)
        return kOfxStatOK

      case .createInstance:
        guard let effect else { return kOfxStatErrBadHandle }
        let instance = try type.init(effect: effect)
        let retained = Unmanaged.passRetained(instance as AnyObject).toOpaque()
        try effect.properties.set(kOfxPropInstanceData, pointer: retained)
        return kOfxStatOK

      case .destroyInstance:
        guard let effect else { return kOfxStatErrBadHandle }
        if let p = try effect.properties.pointer(kOfxPropInstanceData) {
          Unmanaged<AnyObject>.fromOpaque(p).release()
          try effect.properties.set(kOfxPropInstanceData, pointer: nil)
        }
        return kOfxStatOK

      default:
        break
      }

      // Everything else needs the instance object.
      guard let effect, let instance = try Self.instance(of: effect) else { return kOfxStatReplyDefault }

      switch action {
      case .render:
        guard let inProps else { return kOfxStatErrBadHandle }
        try instance.render(try renderArguments(effect, inProps))
        return kOfxStatOK

      case .isIdentity:
        guard let inProps, let outProps else { return kOfxStatErrBadHandle }
        guard let (clip, time) = try instance.isIdentity(try renderArguments(effect, inProps)) else {
          return kOfxStatReplyDefault
        }
        try outProps.set(kOfxPropName, clip)
        try outProps.set(kOfxPropTime, time)
        return kOfxStatOK

      case .instanceChanged:
        guard let inProps else { return kOfxStatErrBadHandle }
        try instance.instanceChanged(OFXInstanceChangedArguments(
          effect: effect,
          type: try inProps.string(kOfxPropType),
          name: try inProps.string(kOfxPropName),
          reason: try inProps.string(kOfxPropChangeReason),
          time: (try? inProps.double(kOfxPropTime)) ?? 0))
        return kOfxStatOK

      case .getRegionOfDefinition:
        guard let inProps, let outProps else { return kOfxStatErrBadHandle }
        guard let rod = try instance.regionOfDefinition(effect: effect, time: try inProps.double(kOfxPropTime)) else {
          return kOfxStatReplyDefault
        }
        try outProps.set(kOfxImageEffectPropRegionOfDefinition, rect: rod)
        return kOfxStatOK

      case .getClipPreferences:
        guard let outProps else { return kOfxStatErrBadHandle }
        return try instance.clipPreferences(effect: effect, preferences: outProps) ? kOfxStatOK : kOfxStatReplyDefault

      default:
        return kOfxStatReplyDefault
      }
    } catch let status as OFXStatus {
      return status.rawValue
    } catch {
      connection.post(.error, "\(type.identifier): \(error)", effect: effect?.handle)
      return kOfxStatFailed
    }
  }

  private static func instance(of effect: OFXEffectRef) throws -> (any OFXEffectPlugin)? {
    guard let p = try? effect.properties.pointer(kOfxPropInstanceData) else { return nil }
    return Unmanaged<AnyObject>.fromOpaque(p).takeUnretainedValue() as? any OFXEffectPlugin
  }

  private static func renderArguments(_ effect: OFXEffectRef, _ args: OFXPropertySetRef) throws -> OFXRenderArguments {
    OFXRenderArguments(
      effect: effect,
      time: try args.double(kOfxPropTime),
      renderWindow: try args.rectI(kOfxImageEffectPropRenderWindow),
      renderScale: (try? args.pointD(kOfxImageEffectPropRenderScale)) ?? OfxPointD(x: 1, y: 1),
      field: OFXImageField(rawValue: (try? args.string(kOfxImageEffectPropFieldToRender)) ?? kOfxImageFieldNone))
  }
}

// Copyright OpenFX and contributors to the OpenFX project.
// SPDX-License-Identifier: BSD-3-Clause

import Foundation
import OpenFX

/// One OpenFX image effect plug-in registered with an `OFXHost`.
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
  /// Where the plug-in came from, for display (e.g. "in-process", or a bundle name).
  public let origin: String
  /// The plug-in binary's location, if it was loaded from a file (`kOfxPluginPropFilePath`).
  public let filePath: String?
  public unowned let host: OFXHost

  public private(set) var state: State = .unloaded
  private var mainDescriptor: OFXImageEffect?
  private var contextDescriptors: [OFXImageEffectContext: OFXImageEffect] = [:]
  private let raw: UnsafeMutablePointer<OfxPlugin>
  private let lock = NSRecursiveLock()

  init(raw: UnsafeMutablePointer<OfxPlugin>, origin: String, filePath: String?, host: OFXHost) {
    self.raw = raw
    self.origin = origin
    self.filePath = filePath
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

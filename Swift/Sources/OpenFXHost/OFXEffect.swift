// Copyright OpenFX and contributors to the OpenFX project.
// SPDX-License-Identifier: BSD-3-Clause

import Foundation
import OpenFX

/// An image effect a host can instantiate, wherever its plug-in code runs.
///
/// `OFXImageEffectPlugin` (a plug-in loaded into this process) conforms, and so
/// does `OFXRemoteEffect` in `OpenFXRemote` (a plug-in running in another process,
/// such as an app extension). Host UI written against these protocols works with both.
public protocol OFXEffect: AnyObject, Sendable {
  var identifier: String { get }
  var versionMajor: UInt32 { get }
  var versionMinor: UInt32 { get }
  var label: String { get }
  var grouping: String { get }
  var pluginDescription: String { get }
  var supportedContexts: [OFXImageEffectContext] { get }
  /// The first context both the plug-in and the host support, preferring filter.
  var preferredContext: OFXImageEffectContext? { get }
  /// Where the plug-in comes from, for display (a bundle name, an app extension name, ...).
  var origin: String { get }

  /// Creates and initialises an instance; `context` defaults to `preferredContext`.
  func makeInstance(context: OFXImageEffectContext?, project: OFXProject,
                    preferredBitDepth: OFXBitDepth) throws -> any OFXEffectInstance
}

/// A live instance of an `OFXEffect`. Implementations are safe to use from any thread.
public protocol OFXEffectInstance: AnyObject, Sendable {
  var context: OFXImageEffectContext { get }
  var project: OFXProject { get }
  /// The instance's parameters, in definition order. Values can be read at any time;
  /// change them with `setValue(_:for:at:)` so the plug-in is told.
  var parameters: [OFXParameter] { get }
  func parameter(named name: String) -> OFXParameter?
  var inputClipNames: [String] { get }

  /// Connects (or with nil, disconnects) an input clip.
  func setInput(_ clipName: String, source: OFXClipSource?) throws
  /// Sets a parameter, optionally as a keyframe, and notifies the plug-in like a user edit.
  func setValue(_ value: OFXParameterValue, for name: String, at time: Double?) throws
  func pressButton(_ name: String) throws
  /// Moves the instance to a new time (the default for untimed parameter reads).
  func setTime(_ time: Double)

  /// Called when the plug-in changes a parameter value itself.
  var onParameterChangedByPlugin: ((OFXParameter) -> Void)? { get set }
  /// Set to ask the plug-in to abandon the current render.
  var abortRequested: Bool { get set }

  /// Renders one frame; see `OFXImageEffectInstance.render(time:interactive:cropToRegionOfDefinition:)`.
  func render(time: Double, interactive: Bool, cropToRegionOfDefinition: Bool) throws -> OFXImageBuffer
}

extension OFXEffect {
  public func makeInstance(context: OFXImageEffectContext? = nil, project: OFXProject) throws -> any OFXEffectInstance {
    try makeInstance(context: context, project: project, preferredBitDepth: .float)
  }
}

extension OFXEffectInstance {
  /// Connects an input clip to a single still image, used at every time.
  public func setInput(_ clipName: String = kOfxImageEffectSimpleSourceClipName, image: OFXImageBuffer?) throws {
    try setInput(clipName, source: image.map { img in { _ in img } })
  }

  public func setValue(_ value: OFXParameterValue, for name: String) throws {
    try setValue(value, for: name, at: nil)
  }

  public func render(time: Double) throws -> OFXImageBuffer {
    try render(time: time, interactive: false, cropToRegionOfDefinition: false)
  }
}

extension OFXImageEffectPlugin: OFXEffect {
  public var pluginDescription: String { (try? describe())?.pluginDescription ?? "" }

  public func makeInstance(context: OFXImageEffectContext?, project: OFXProject,
                           preferredBitDepth: OFXBitDepth) throws -> any OFXEffectInstance {
    try createInstance(context: context, project: project, preferredBitDepth: preferredBitDepth)
  }
}

extension OFXImageEffectInstance: OFXEffectInstance {}

// Copyright OpenFX and contributors to the OpenFX project.
// SPDX-License-Identifier: BSD-3-Clause

import OpenFX

/// Arguments of `kOfxImageEffectActionRender` and `kOfxImageEffectActionIsIdentity`.
public struct OFXRenderArguments {
  public let effect: OFXEffectRef
  public let time: Double
  public let renderWindow: OfxRectI
  public let renderScale: OfxPointD
  public let field: OFXImageField
}

/// Arguments of `kOfxActionInstanceChanged`.
public struct OFXInstanceChangedArguments {
  public let effect: OFXEffectRef
  /// `kOfxTypeParameter` or `kOfxTypeClip`.
  public let type: String
  /// Name of the parameter or clip that changed.
  public let name: String
  /// `kOfxChangeUserEdited`, `kOfxChangePluginEdited` or `kOfxChangeTime`.
  public let reason: String
  public let time: Double
}

/// An OpenFX image effect plug-in written in Swift.
///
/// Conforming classes are exported by an `OFXPluginRegistry`; one object is
/// created per effect instance.
///
/// ```swift
/// final class Gain: OFXEffectPlugin {
///   static let identifier = "com.example.Gain"
///   static func describe(_ effect: OFXEffectRef) throws {
///     try effect.setDescription(label: "Gain", contexts: [.filter])
///   }
///   static func describeInContext(_ effect: OFXEffectRef, context: OFXImageEffectContext) throws {
///     try effect.defineClip(kOfxImageEffectSimpleSourceClipName)
///     try effect.defineClip(kOfxImageEffectOutputClipName)
///     try effect.defineDouble("gain", label: "Gain", default: 1, range: 0...4)
///   }
///   init(effect: OFXEffectRef) throws {}
///   func render(_ args: OFXRenderArguments) throws { ... }
/// }
/// ```
public protocol OFXEffectPlugin: AnyObject {
  /// Reverse-domain identifier, unique among plug-ins.
  static var identifier: String { get }
  static var versionMajor: UInt32 { get }
  static var versionMinor: UInt32 { get }

  /// `kOfxActionDescribe`: set labels, supported contexts and pixel depths.
  static func describe(_ effect: OFXEffectRef) throws
  /// `kOfxImageEffectActionDescribeInContext`: define clips and parameters.
  static func describeInContext(_ effect: OFXEffectRef, context: OFXImageEffectContext) throws

  /// `kOfxActionCreateInstance`.
  init(effect: OFXEffectRef) throws

  /// `kOfxImageEffectActionRender`.
  func render(_ args: OFXRenderArguments) throws

  /// `kOfxImageEffectActionIsIdentity`: return a clip name and time to pass that
  /// clip through unchanged, or nil to render.
  func isIdentity(_ args: OFXRenderArguments) throws -> (clip: String, time: Double)?

  /// `kOfxActionInstanceChanged`.
  func instanceChanged(_ args: OFXInstanceChangedArguments) throws

  /// `kOfxImageEffectActionGetRegionOfDefinition`: return nil for the host's default.
  func regionOfDefinition(effect: OFXEffectRef, time: Double) throws -> OfxRectD?

  /// `kOfxImageEffectActionGetClipPreferences`: edit `preferences` and return true
  /// if anything changed.
  func clipPreferences(effect: OFXEffectRef, preferences: OFXPropertySetRef) throws -> Bool
}

extension OFXEffectPlugin {
  public static var versionMajor: UInt32 { 1 }
  public static var versionMinor: UInt32 { 0 }
  public func isIdentity(_ args: OFXRenderArguments) throws -> (clip: String, time: Double)? { nil }
  public func instanceChanged(_ args: OFXInstanceChangedArguments) throws {}
  public func regionOfDefinition(effect: OFXEffectRef, time: Double) throws -> OfxRectD? { nil }
  public func clipPreferences(effect: OFXEffectRef, preferences: OFXPropertySetRef) throws -> Bool { false }
}

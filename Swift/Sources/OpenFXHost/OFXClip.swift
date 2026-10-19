// Copyright OpenFX and contributors to the OpenFX project.
// SPDX-License-Identifier: BSD-3-Clause

import Foundation
import OpenFX

/// Supplies frames for an input clip. Return `nil` when no frame exists at `time`.
public typealias OFXClipSource = (_ time: Double) throws -> OFXImageBuffer?

/// A clip descriptor or instance. Its handle is the `OfxImageClipHandle` given to plug-ins.
public final class OFXClip {
  public let name: String
  public let properties: OFXPropertySet
  public private(set) weak var effect: OFXImageEffect?

  /// Where the frames of an input clip come from. Unused for the output clip.
  public internal(set) var source: OFXClipSource?

  init(name: String, properties: OFXPropertySet, effect: OFXImageEffect) {
    self.name = name
    self.properties = properties
    self.effect = effect
  }

  public var handle: OfxImageClipHandle { OpaquePointer(Unmanaged.passUnretained(self).toOpaque()) }

  static func from(_ handle: OfxImageClipHandle?) -> OFXClip? {
    guard let handle else { return nil }
    return Unmanaged<OFXClip>.fromOpaque(UnsafeRawPointer(handle)).takeUnretainedValue()
  }

  public var isOutput: Bool { name == kOfxImageEffectOutputClipName }
  public var isOptional: Bool { properties.bool(kOfxImageClipPropOptional) ?? false }
  public var isMask: Bool { properties.bool(kOfxImageClipPropIsMask) ?? false }
  public var label: String { properties.string(kOfxPropLabel) ?? name }
  public var supportedComponents: [OFXImageComponents] {
    properties.strings(kOfxImageEffectPropSupportedComponents).map(OFXImageComponents.init(rawValue:))
  }
  public var isConnected: Bool { properties.bool(kOfxImageClipPropConnected) ?? false }

  /// The pixel depth images of this clip are delivered in (instances only).
  public var pixelDepth: OFXBitDepth {
    OFXBitDepth(rawValue: properties.string(kOfxImageEffectPropPixelDepth) ?? kOfxBitDepthNone)
  }

  /// The components images of this clip are delivered in (instances only).
  public var components: OFXImageComponents {
    OFXImageComponents(rawValue: properties.string(kOfxImageEffectPropComponents) ?? kOfxImageComponentNone)
  }

  public var premultiplication: OFXPremultiplication {
    OFXPremultiplication(rawValue: properties.string(kOfxImageEffectPropPreMultiplication) ?? kOfxImagePreMultiplied)
  }

  static func descriptorProperties(name: String) -> OFXPropertySet {
    let p = OFXPropertySet(debugName: "clip \(name)")
    p.set(kOfxPropType, kOfxTypeClip)
    p.define(kOfxPropName, .string([name]), readOnly: true)
    p.set(kOfxPropLabel, name)
    p.set(kOfxPropShortLabel, name)
    p.set(kOfxPropLongLabel, name)
    p[kOfxImageEffectPropSupportedComponents] = .string([])
    p.set(kOfxImageEffectPropTemporalClipAccess, false)
    p.set(kOfxImageClipPropOptional, false)
    p.set(kOfxImageClipPropIsMask, false)
    p.set(kOfxImageClipPropFieldExtraction, kOfxImageFieldDoubled)
    p.set(kOfxImageEffectPropSupportsTiles, true)
    return p
  }
}

/// The property set returned by `clipGetImage`; it keeps its pixels alive until released.
final class OFXImage: OFXPropertySet {
  let buffer: OFXImageBuffer
  /// The instance that issued the image, which releases it.
  weak var owner: OFXImageEffectInstance?

  init(buffer: OFXImageBuffer, clipName: String, time: Double, uniqueID: String) {
    self.buffer = buffer
    super.init(debugName: "image \(clipName)@\(time)")
    set(kOfxPropType, kOfxTypeImage)
    set(kOfxImageEffectPropPixelDepth, buffer.bitDepth.rawValue)
    set(kOfxImageEffectPropComponents, buffer.components.rawValue)
    set(kOfxImageEffectPropPreMultiplication, buffer.premultiplication.rawValue)
    set(kOfxImageEffectPropRenderScale, doubles: [1, 1])
    set(kOfxImagePropPixelAspectRatio, buffer.pixelAspectRatio)
    set(kOfxImagePropData, pointer: buffer.data)
    set(kOfxImagePropBounds, rect: buffer.bounds)
    set(kOfxImagePropRegionOfDefinition, rect: buffer.bounds)
    set(kOfxImagePropRowBytes, buffer.rowBytes)
    set(kOfxImagePropField, kOfxImageFieldNone)
    set(kOfxImagePropUniqueIdentifier, uniqueID)
  }
}

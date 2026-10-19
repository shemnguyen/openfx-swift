// Copyright OpenFX and contributors to the OpenFX project.
// SPDX-License-Identifier: BSD-3-Clause

/// A string valued OpenFX constant (`kOfx...` macro) with a typed wrapper.
///
/// The raw C macros are still available from `OpenFXC` as plain `String`s; these
/// wrappers exist so APIs can say *which* kind of string they want.
public protocol OFXStringConstant: RawRepresentable, Hashable, Sendable,
  ExpressibleByStringLiteral, CustomStringConvertible where RawValue == String
{
  init(rawValue: String)
}

extension OFXStringConstant {
  public init(stringLiteral value: String) { self.init(rawValue: value) }
  public var description: String { rawValue }
}

/// Actions passed to a plug-in's main entry point.
public struct OFXAction: OFXStringConstant {
  public var rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }

  // Generic actions (ofxCore.h)
  public static let load = Self(rawValue: kOfxActionLoad)
  public static let describe = Self(rawValue: kOfxActionDescribe)
  public static let unload = Self(rawValue: kOfxActionUnload)
  public static let purgeCaches = Self(rawValue: kOfxActionPurgeCaches)
  public static let syncPrivateData = Self(rawValue: kOfxActionSyncPrivateData)
  public static let createInstance = Self(rawValue: kOfxActionCreateInstance)
  public static let destroyInstance = Self(rawValue: kOfxActionDestroyInstance)
  public static let instanceChanged = Self(rawValue: kOfxActionInstanceChanged)
  public static let beginInstanceChanged = Self(rawValue: kOfxActionBeginInstanceChanged)
  public static let endInstanceChanged = Self(rawValue: kOfxActionEndInstanceChanged)
  public static let beginInstanceEdit = Self(rawValue: kOfxActionBeginInstanceEdit)
  public static let endInstanceEdit = Self(rawValue: kOfxActionEndInstanceEdit)

  // Image effect actions (ofxImageEffect.h)
  public static let getRegionOfDefinition = Self(rawValue: kOfxImageEffectActionGetRegionOfDefinition)
  public static let getRegionsOfInterest = Self(rawValue: kOfxImageEffectActionGetRegionsOfInterest)
  public static let getTimeDomain = Self(rawValue: kOfxImageEffectActionGetTimeDomain)
  public static let getFramesNeeded = Self(rawValue: kOfxImageEffectActionGetFramesNeeded)
  public static let getClipPreferences = Self(rawValue: kOfxImageEffectActionGetClipPreferences)
  public static let isIdentity = Self(rawValue: kOfxImageEffectActionIsIdentity)
  public static let render = Self(rawValue: kOfxImageEffectActionRender)
  public static let beginSequenceRender = Self(rawValue: kOfxImageEffectActionBeginSequenceRender)
  public static let endSequenceRender = Self(rawValue: kOfxImageEffectActionEndSequenceRender)
  public static let describeInContext = Self(rawValue: kOfxImageEffectActionDescribeInContext)
  public static let getOutputColourspace = Self(rawValue: kOfxImageEffectActionGetOutputColourspace)
}

/// Image effect contexts (`kOfxImageEffectContext*`).
public struct OFXImageEffectContext: OFXStringConstant {
  public var rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }

  public static let generator = Self(rawValue: kOfxImageEffectContextGenerator)
  public static let filter = Self(rawValue: kOfxImageEffectContextFilter)
  public static let transition = Self(rawValue: kOfxImageEffectContextTransition)
  public static let paint = Self(rawValue: kOfxImageEffectContextPaint)
  public static let general = Self(rawValue: kOfxImageEffectContextGeneral)
  public static let retimer = Self(rawValue: kOfxImageEffectContextRetimer)
}

/// Pixel bit depths (`kOfxBitDepth*`).
public struct OFXBitDepth: OFXStringConstant {
  public var rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }

  public static let none = Self(rawValue: kOfxBitDepthNone)
  public static let byte = Self(rawValue: kOfxBitDepthByte)
  public static let short = Self(rawValue: kOfxBitDepthShort)
  public static let half = Self(rawValue: kOfxBitDepthHalf)
  public static let float = Self(rawValue: kOfxBitDepthFloat)

  /// Size of one component in bytes, or 0 for unknown depths.
  public var bytesPerComponent: Int {
    switch self {
    case .byte: return 1
    case .short, .half: return 2
    case .float: return 4
    default: return 0
    }
  }
}

/// Pixel components (`kOfxImageComponent*`).
public struct OFXImageComponents: OFXStringConstant {
  public var rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }

  public static let none = Self(rawValue: kOfxImageComponentNone)
  public static let rgba = Self(rawValue: kOfxImageComponentRGBA)
  public static let rgb = Self(rawValue: kOfxImageComponentRGB)
  public static let alpha = Self(rawValue: kOfxImageComponentAlpha)

  /// Number of components per pixel, or 0 for unknown component types.
  public var count: Int {
    switch self {
    case .rgba: return 4
    case .rgb: return 3
    case .alpha: return 1
    default: return 0
    }
  }
}

/// Image premultiplication states (`kOfxImageOpaque` etc).
public struct OFXPremultiplication: OFXStringConstant {
  public var rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }

  public static let opaque = Self(rawValue: kOfxImageOpaque)
  public static let premultiplied = Self(rawValue: kOfxImagePreMultiplied)
  public static let unpremultiplied = Self(rawValue: kOfxImageUnPreMultiplied)
}

/// Image field values (`kOfxImageField*`).
public struct OFXImageField: OFXStringConstant {
  public var rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }

  public static let none = Self(rawValue: kOfxImageFieldNone)
  public static let lower = Self(rawValue: kOfxImageFieldLower)
  public static let upper = Self(rawValue: kOfxImageFieldUpper)
  public static let both = Self(rawValue: kOfxImageFieldBoth)
  public static let single = Self(rawValue: kOfxImageFieldSingle)
  public static let doubled = Self(rawValue: kOfxImageFieldDoubled)
}

/// Parameter types (`kOfxParamType*`).
public struct OFXParamType: OFXStringConstant {
  public var rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }

  public static let integer = Self(rawValue: kOfxParamTypeInteger)
  public static let double = Self(rawValue: kOfxParamTypeDouble)
  public static let boolean = Self(rawValue: kOfxParamTypeBoolean)
  public static let choice = Self(rawValue: kOfxParamTypeChoice)
  public static let strChoice = Self(rawValue: kOfxParamTypeStrChoice)
  public static let rgba = Self(rawValue: kOfxParamTypeRGBA)
  public static let rgb = Self(rawValue: kOfxParamTypeRGB)
  public static let double2D = Self(rawValue: kOfxParamTypeDouble2D)
  public static let integer2D = Self(rawValue: kOfxParamTypeInteger2D)
  public static let double3D = Self(rawValue: kOfxParamTypeDouble3D)
  public static let integer3D = Self(rawValue: kOfxParamTypeInteger3D)
  public static let string = Self(rawValue: kOfxParamTypeString)
  public static let custom = Self(rawValue: kOfxParamTypeCustom)
  public static let bytes = Self(rawValue: kOfxParamTypeBytes)
  public static let group = Self(rawValue: kOfxParamTypeGroup)
  public static let page = Self(rawValue: kOfxParamTypePage)
  public static let pushButton = Self(rawValue: kOfxParamTypePushButton)
  public static let parametric = Self(rawValue: kOfxParamTypeParametric)

  /// How values of this type travel through the (variadic) parameter suite.
  public var valueLayout: (kind: OfxSwiftParamValueKind, count: Int) {
    switch self {
    case .integer, .boolean, .choice: return (OfxSwiftParamValueKindInt, 1)
    case .integer2D: return (OfxSwiftParamValueKindInt, 2)
    case .integer3D: return (OfxSwiftParamValueKindInt, 3)
    case .double: return (OfxSwiftParamValueKindDouble, 1)
    case .double2D: return (OfxSwiftParamValueKindDouble, 2)
    case .double3D, .rgb: return (OfxSwiftParamValueKindDouble, 3)
    case .rgba: return (OfxSwiftParamValueKindDouble, 4)
    case .string, .custom, .strChoice: return (OfxSwiftParamValueKindString, 1)
    default: return (OfxSwiftParamValueKindNone, 0)
    }
  }
}

/// Message types for the message suite (`kOfxMessage*`).
public struct OFXMessageType: OFXStringConstant {
  public var rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }

  public static let fatal = Self(rawValue: kOfxMessageFatal)
  public static let error = Self(rawValue: kOfxMessageError)
  public static let warning = Self(rawValue: kOfxMessageWarning)
  public static let message = Self(rawValue: kOfxMessageMessage)
  public static let log = Self(rawValue: kOfxMessageLog)
  public static let question = Self(rawValue: kOfxMessageQuestion)
}

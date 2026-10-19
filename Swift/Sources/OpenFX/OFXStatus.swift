// Copyright OpenFX and contributors to the OpenFX project.
// SPDX-License-Identifier: BSD-3-Clause

@_exported import OpenFXC

/// A Swift view of `OfxStatus`, usable as an `Error`.
public struct OFXStatus: RawRepresentable, Hashable, Error, Sendable, CustomStringConvertible {
  public var rawValue: OfxStatus

  public init(rawValue: OfxStatus) { self.rawValue = rawValue }
  public init(_ rawValue: OfxStatus) { self.rawValue = rawValue }

  public static let ok = OFXStatus(kOfxStatOK)
  public static let failed = OFXStatus(kOfxStatFailed)
  public static let errFatal = OFXStatus(kOfxStatErrFatal)
  public static let errUnknown = OFXStatus(kOfxStatErrUnknown)
  public static let errMissingHostFeature = OFXStatus(kOfxStatErrMissingHostFeature)
  public static let errUnsupported = OFXStatus(kOfxStatErrUnsupported)
  public static let errExists = OFXStatus(kOfxStatErrExists)
  public static let errFormat = OFXStatus(kOfxStatErrFormat)
  public static let errMemory = OFXStatus(kOfxStatErrMemory)
  public static let errBadHandle = OFXStatus(kOfxStatErrBadHandle)
  public static let errBadIndex = OFXStatus(kOfxStatErrBadIndex)
  public static let errValue = OFXStatus(kOfxStatErrValue)
  public static let replyYes = OFXStatus(kOfxStatReplyYes)
  public static let replyNo = OFXStatus(kOfxStatReplyNo)
  public static let replyDefault = OFXStatus(kOfxStatReplyDefault)
  public static let unlicensed = OFXStatus(kOfxStatUnlicensed)
  public static let errImageFormat = OFXStatus(kOfxStatErrImageFormat)
  public static let gpuOutOfMemory = OFXStatus(kOfxStatGPUOutOfMemory)
  public static let gpuRenderFailed = OFXStatus(kOfxStatGPURenderFailed)

  /// `true` for `kOfxStatOK` and `kOfxStatReplyDefault`, the two "nothing went wrong" replies.
  public var isSuccess: Bool { self == .ok || self == .replyDefault }

  public var name: String {
    switch self {
    case .ok: return "kOfxStatOK"
    case .failed: return "kOfxStatFailed"
    case .errFatal: return "kOfxStatErrFatal"
    case .errUnknown: return "kOfxStatErrUnknown"
    case .errMissingHostFeature: return "kOfxStatErrMissingHostFeature"
    case .errUnsupported: return "kOfxStatErrUnsupported"
    case .errExists: return "kOfxStatErrExists"
    case .errFormat: return "kOfxStatErrFormat"
    case .errMemory: return "kOfxStatErrMemory"
    case .errBadHandle: return "kOfxStatErrBadHandle"
    case .errBadIndex: return "kOfxStatErrBadIndex"
    case .errValue: return "kOfxStatErrValue"
    case .replyYes: return "kOfxStatReplyYes"
    case .replyNo: return "kOfxStatReplyNo"
    case .replyDefault: return "kOfxStatReplyDefault"
    case .unlicensed: return "kOfxStatUnlicensed"
    case .errImageFormat: return "kOfxStatErrImageFormat"
    case .gpuOutOfMemory: return "kOfxStatGPUOutOfMemory"
    case .gpuRenderFailed: return "kOfxStatGPURenderFailed"
    default: return "OfxStatus(\(rawValue))"
    }
  }

  public var description: String { name }

  /// Throws unless `status` is `kOfxStatOK`.
  @inlinable
  public static func check(_ status: OfxStatus) throws {
    if status != kOfxStatOK { throw OFXStatus(status) }
  }

  /// Converts a thrown error back into an `OfxStatus` for returning across the C boundary.
  public static func from(_ error: Error) -> OfxStatus {
    (error as? OFXStatus)?.rawValue ?? kOfxStatFailed
  }
}

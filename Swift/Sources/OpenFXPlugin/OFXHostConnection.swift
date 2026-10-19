// Copyright OpenFX and contributors to the OpenFX project.
// SPDX-License-Identifier: BSD-3-Clause

import OpenFX

/// The host a Swift plug-in binary is connected to, and the suites fetched from it.
public struct OFXHostConnection {
  public let host: UnsafePointer<OfxHost>
  public let property: UnsafePointer<OfxPropertySuiteV1>
  public let imageEffect: UnsafePointer<OfxImageEffectSuiteV1>
  public let parameter: UnsafePointer<OfxParameterSuiteV1>
  public let memory: UnsafePointer<OfxMemorySuiteV1>?
  public let multiThread: UnsafePointer<OfxMultiThreadSuiteV1>?
  public let message: UnsafePointer<OfxMessageSuiteV1>?
  public let progress: UnsafePointer<OfxProgressSuiteV1>?

  /// The connection set up by the host's `setHost` call, once it has happened.
  public internal(set) static var current: OFXHostConnection?

  init?(host: UnsafePointer<OfxHost>) {
    func fetch<T>(_ name: String, _ version: Int32, as: T.Type) -> UnsafePointer<T>? {
      host.pointee.fetchSuite?(host.pointee.host, name, version)?.assumingMemoryBound(to: T.self)
    }
    guard let property = fetch(kOfxPropertySuite, 1, as: OfxPropertySuiteV1.self),
          let imageEffect = fetch(kOfxImageEffectSuite, 1, as: OfxImageEffectSuiteV1.self),
          let parameter = fetch(kOfxParameterSuite, 1, as: OfxParameterSuiteV1.self)
    else { return nil }
    self.host = host
    self.property = property
    self.imageEffect = imageEffect
    self.parameter = parameter
    self.memory = fetch(kOfxMemorySuite, 1, as: OfxMemorySuiteV1.self)
    self.multiThread = fetch(kOfxMultiThreadSuite, 1, as: OfxMultiThreadSuiteV1.self)
    self.message = fetch(kOfxMessageSuite, 1, as: OfxMessageSuiteV1.self)
    self.progress = fetch(kOfxProgressSuite, 1, as: OfxProgressSuiteV1.self)
  }

  /// The host descriptor (`kOfxPropName`, `kOfxImageEffectPropSupportedPixelDepths`, ...).
  public var hostProperties: OFXPropertySetRef { OFXPropertySetRef(host.pointee.host!, suite: property) }

  public func properties(_ handle: OfxPropertySetHandle) -> OFXPropertySetRef {
    OFXPropertySetRef(handle, suite: property)
  }

  /// Posts a message to the user through the message suite.
  @discardableResult
  public func post(_ type: OFXMessageType, _ text: String, effect: OfxImageEffectHandle? = nil,
                   id: String? = nil) -> OFXStatus {
    guard let message else { return .errUnsupported }
    let raw = UnsafeMutableRawPointer(effect)
    if let id {
      return OFXStatus(OfxSwiftCallMessage(message, raw, type.rawValue, id, text))
    }
    return OFXStatus(OfxSwiftCallMessage(message, raw, type.rawValue, nil, text))
  }
}

// Copyright OpenFX and contributors to the OpenFX project.
// SPDX-License-Identifier: BSD-3-Clause

import OpenFX

/// A plug-in's view of an image effect handle (descriptor or instance).
public struct OFXEffectRef {
  public let handle: OfxImageEffectHandle
  public let connection: OFXHostConnection

  public init(_ handle: OfxImageEffectHandle, connection: OFXHostConnection) {
    self.handle = handle
    self.connection = connection
  }

  public var properties: OFXPropertySetRef {
    var p: OfxPropertySetHandle?
    _ = connection.imageEffect.pointee.getPropertySet(handle, &p)
    return connection.properties(p!)
  }

  public var parameterSet: OfxParamSetHandle {
    var p: OfxParamSetHandle?
    _ = connection.imageEffect.pointee.getParamSet(handle, &p)
    return p!
  }

  /// The context of a context descriptor or instance.
  public var context: OFXImageEffectContext {
    OFXImageEffectContext(rawValue: (try? properties.string(kOfxImageEffectPropContext)) ?? "")
  }

  /// Whether the host wants the current render abandoned.
  public var isAborted: Bool { connection.imageEffect.pointee.abort(handle) != 0 }

  // MARK: Describing

  /// Sets the common descriptor properties in one go.
  public func setDescription(label: String, grouping: String = "", description: String = "",
                             contexts: [OFXImageEffectContext],
                             pixelDepths: [OFXBitDepth] = [.byte, .short, .float],
                             supportsTiles: Bool = true, supportsMultiResolution: Bool = true) throws {
    let p = properties
    try p.set(kOfxPropLabel, label)
    if !grouping.isEmpty { try p.set(kOfxImageEffectPluginPropGrouping, grouping) }
    if !description.isEmpty { try p.set(kOfxPropPluginDescription, description) }
    try p.set(kOfxImageEffectPropSupportedContexts, strings: contexts.map(\.rawValue))
    try p.set(kOfxImageEffectPropSupportedPixelDepths, strings: pixelDepths.map(\.rawValue))
    try p.set(kOfxImageEffectPropSupportsTiles, supportsTiles)
    try p.set(kOfxImageEffectPropSupportsMultiResolution, supportsMultiResolution)
  }

  /// Defines a clip (in `describeInContext`) and returns its descriptor properties.
  @discardableResult
  public func defineClip(_ name: String, components: [OFXImageComponents] = [.rgba],
                         optional: Bool = false, supportsTiles: Bool = true) throws -> OFXPropertySetRef {
    var p: OfxPropertySetHandle?
    try OFXStatus.check(connection.imageEffect.pointee.clipDefine(handle, name, &p))
    let props = connection.properties(p!)
    try props.set(kOfxImageEffectPropSupportedComponents, strings: components.map(\.rawValue))
    try props.set(kOfxImageClipPropOptional, optional)
    try props.set(kOfxImageEffectPropSupportsTiles, supportsTiles)
    return props
  }

  /// Defines a parameter (in `describeInContext`) and returns its descriptor properties.
  @discardableResult
  public func defineParameter(_ type: OFXParamType, name: String, label: String? = nil,
                              hint: String? = nil, parent: String? = nil) throws -> OFXPropertySetRef {
    var p: OfxPropertySetHandle?
    try OFXStatus.check(connection.parameter.pointee.paramDefine(parameterSet, type.rawValue, name, &p))
    let props = connection.properties(p!)
    if let label { try props.set(kOfxPropLabel, label) }
    if let hint { try props.set(kOfxParamPropHint, hint) }
    if let parent { try props.set(kOfxParamPropParent, parent) }
    return props
  }

  @discardableResult
  public func defineDouble(_ name: String, label: String, default value: Double,
                           range: ClosedRange<Double>? = nil, displayRange: ClosedRange<Double>? = nil,
                           hint: String? = nil, parent: String? = nil) throws -> OFXPropertySetRef {
    let p = try defineParameter(.double, name: name, label: label, hint: hint, parent: parent)
    try p.set(kOfxParamPropDefault, value)
    if let range {
      try p.set(kOfxParamPropMin, range.lowerBound)
      try p.set(kOfxParamPropMax, range.upperBound)
    }
    if let r = displayRange ?? range {
      try p.set(kOfxParamPropDisplayMin, r.lowerBound)
      try p.set(kOfxParamPropDisplayMax, r.upperBound)
    }
    return p
  }

  @discardableResult
  public func defineInt(_ name: String, label: String, default value: Int,
                        range: ClosedRange<Int>? = nil, hint: String? = nil,
                        parent: String? = nil) throws -> OFXPropertySetRef {
    let p = try defineParameter(.integer, name: name, label: label, hint: hint, parent: parent)
    try p.set(kOfxParamPropDefault, value)
    if let range {
      try p.set(kOfxParamPropMin, range.lowerBound)
      try p.set(kOfxParamPropMax, range.upperBound)
      try p.set(kOfxParamPropDisplayMin, range.lowerBound)
      try p.set(kOfxParamPropDisplayMax, range.upperBound)
    }
    return p
  }

  @discardableResult
  public func defineBoolean(_ name: String, label: String, default value: Bool,
                            hint: String? = nil, parent: String? = nil) throws -> OFXPropertySetRef {
    let p = try defineParameter(.boolean, name: name, label: label, hint: hint, parent: parent)
    try p.set(kOfxParamPropDefault, value)
    return p
  }

  @discardableResult
  public func defineChoice(_ name: String, label: String, options: [String], default index: Int = 0,
                           hint: String? = nil, parent: String? = nil) throws -> OFXPropertySetRef {
    let p = try defineParameter(.choice, name: name, label: label, hint: hint, parent: parent)
    try p.set(kOfxParamPropChoiceOption, strings: options)
    try p.set(kOfxParamPropDefault, index)
    return p
  }

  @discardableResult
  public func defineRGB(_ name: String, label: String, default value: SIMD3<Double>,
                        hint: String? = nil, parent: String? = nil) throws -> OFXPropertySetRef {
    let p = try defineParameter(.rgb, name: name, label: label, hint: hint, parent: parent)
    try p.set(kOfxParamPropDefault, doubles: [value.x, value.y, value.z])
    return p
  }

  @discardableResult
  public func defineRGBA(_ name: String, label: String, default value: SIMD4<Double>,
                         hint: String? = nil, parent: String? = nil) throws -> OFXPropertySetRef {
    let p = try defineParameter(.rgba, name: name, label: label, hint: hint, parent: parent)
    try p.set(kOfxParamPropDefault, doubles: [value.x, value.y, value.z, value.w])
    return p
  }

  // MARK: Instances

  public func clip(_ name: String) throws -> OFXClipRef {
    var clip: OfxImageClipHandle?
    try OFXStatus.check(connection.imageEffect.pointee.clipGetHandle(handle, name, &clip, nil))
    return OFXClipRef(handle: clip!, connection: connection)
  }

  public func parameter(_ name: String) throws -> OFXParamRef {
    var param: OfxParamHandle?
    try OFXStatus.check(connection.parameter.pointee.paramGetHandle(parameterSet, name, &param, nil))
    return OFXParamRef(handle: param!, connection: connection)
  }
}

/// A plug-in's view of a clip.
public struct OFXClipRef {
  public let handle: OfxImageClipHandle
  public let connection: OFXHostConnection

  public var properties: OFXPropertySetRef {
    var p: OfxPropertySetHandle?
    _ = connection.imageEffect.pointee.clipGetPropertySet(handle, &p)
    return connection.properties(p!)
  }

  public var isConnected: Bool { (try? properties.bool(kOfxImageClipPropConnected)) ?? false }

  public var pixelDepth: OFXBitDepth {
    OFXBitDepth(rawValue: (try? properties.string(kOfxImageEffectPropPixelDepth)) ?? "")
  }

  public var components: OFXImageComponents {
    OFXImageComponents(rawValue: (try? properties.string(kOfxImageEffectPropComponents)) ?? "")
  }

  /// Fetches the image at `time`; release it with `OFXImageRef.release()`, or use `withImage`.
  public func image(at time: Double, region: OfxRectD? = nil) throws -> OFXImageRef {
    var props: OfxPropertySetHandle?
    var r = region ?? OfxRectD()
    let stat = region == nil
      ? connection.imageEffect.pointee.clipGetImage(handle, time, nil, &props)
      : connection.imageEffect.pointee.clipGetImage(handle, time, &r, &props)
    try OFXStatus.check(stat)
    return try OFXImageRef(handle: props!, connection: connection)
  }

  /// Fetches the image at `time`, runs `body`, and releases the image.
  public func withImage<T>(at time: Double, _ body: (OFXImageRef) throws -> T) throws -> T {
    let image = try image(at: time)
    defer { image.release() }
    return try body(image)
  }

  public func regionOfDefinition(at time: Double) throws -> OfxRectD {
    var r = OfxRectD()
    try OFXStatus.check(connection.imageEffect.pointee.clipGetRegionOfDefinition(handle, time, &r))
    return r
  }
}

/// A plug-in's view of an image fetched from a clip.
public struct OFXImageRef {
  public let handle: OfxPropertySetHandle
  public let connection: OFXHostConnection
  public let data: UnsafeMutableRawPointer
  public let bounds: OfxRectI
  public let rowBytes: Int
  public let pixelDepth: OFXBitDepth
  public let components: OFXImageComponents

  init(handle: OfxPropertySetHandle, connection: OFXHostConnection) throws {
    self.handle = handle
    self.connection = connection
    let p = connection.properties(handle)
    guard let data = try p.pointer(kOfxImagePropData) else { throw OFXStatus.errBadHandle }
    self.data = data
    self.bounds = try p.rectI(kOfxImagePropBounds)
    self.rowBytes = try p.int(kOfxImagePropRowBytes)
    self.pixelDepth = OFXBitDepth(rawValue: try p.string(kOfxImageEffectPropPixelDepth))
    self.components = OFXImageComponents(rawValue: try p.string(kOfxImageEffectPropComponents))
  }

  public var properties: OFXPropertySetRef { connection.properties(handle) }
  public var bytesPerPixel: Int { pixelDepth.bytesPerComponent * components.count }

  /// Address of pixel `(x, y)`, or nil when outside the image bounds.
  public func pixelAddress(x: Int, y: Int) -> UnsafeMutableRawPointer? {
    guard x >= bounds.x1, x < bounds.x2, y >= bounds.y1, y < bounds.y2 else { return nil }
    return data + (y - Int(bounds.y1)) * rowBytes + (x - Int(bounds.x1)) * bytesPerPixel
  }

  public func release() {
    _ = connection.imageEffect.pointee.clipReleaseImage(handle)
  }
}

/// A plug-in's view of a parameter instance.
///
/// The getters and setters go through the host's variadic `paramGetValue*` /
/// `paramSetValue*` functions via the C shims in `OpenFXC`.
public struct OFXParamRef {
  public let handle: OfxParamHandle
  public let connection: OFXHostConnection

  public var properties: OFXPropertySetRef {
    var p: OfxPropertySetHandle?
    _ = connection.parameter.pointee.paramGetPropertySet(handle, &p)
    return connection.properties(p!)
  }

  private func get(_ kind: OfxSwiftParamValueKind, _ count: Int, at time: Double?) throws -> OfxSwiftParamValue {
    var v = OfxSwiftParamValue()
    try OFXStatus.check(OfxSwiftCallParamGetValue(connection.parameter, handle, time == nil ? 0 : 1,
                                                  time ?? 0, kind, Int32(count), &v))
    return v
  }

  private func set(_ kind: OfxSwiftParamValueKind, _ count: Int, at time: Double?, _ v: OfxSwiftParamValue) throws {
    var v = v
    try OFXStatus.check(OfxSwiftCallParamSetValue(connection.parameter, handle, time == nil ? 0 : 1,
                                                  time ?? 0, kind, Int32(count), &v))
  }

  public func double(at time: Double? = nil) throws -> Double {
    try get(OfxSwiftParamValueKindDouble, 1, at: time).doubles.0
  }

  public func double2D(at time: Double? = nil) throws -> SIMD2<Double> {
    let d = try get(OfxSwiftParamValueKindDouble, 2, at: time).doubles
    return SIMD2(d.0, d.1)
  }

  public func double3D(at time: Double? = nil) throws -> SIMD3<Double> {
    let d = try get(OfxSwiftParamValueKindDouble, 3, at: time).doubles
    return SIMD3(d.0, d.1, d.2)
  }

  public func rgb(at time: Double? = nil) throws -> SIMD3<Double> { try double3D(at: time) }

  public func rgba(at time: Double? = nil) throws -> SIMD4<Double> {
    let d = try get(OfxSwiftParamValueKindDouble, 4, at: time).doubles
    return SIMD4(d.0, d.1, d.2, d.3)
  }

  public func int(at time: Double? = nil) throws -> Int {
    Int(try get(OfxSwiftParamValueKindInt, 1, at: time).ints.0)
  }

  public func int2D(at time: Double? = nil) throws -> SIMD2<Int32> {
    let i = try get(OfxSwiftParamValueKindInt, 2, at: time).ints
    return SIMD2(i.0, i.1)
  }

  public func bool(at time: Double? = nil) throws -> Bool { try int(at: time) != 0 }

  /// Value of a string, custom or string-choice parameter.
  public func string(at time: Double? = nil) throws -> String {
    let v = try get(OfxSwiftParamValueKindString, 1, at: time)
    return v.string.map { String(cString: $0) } ?? ""
  }

  public func set(_ value: Double, at time: Double? = nil) throws {
    var v = OfxSwiftParamValue()
    v.doubles.0 = value
    try set(OfxSwiftParamValueKindDouble, 1, at: time, v)
  }

  public func set(_ value: Int, at time: Double? = nil) throws {
    var v = OfxSwiftParamValue()
    v.ints.0 = Int32(value)
    try set(OfxSwiftParamValueKindInt, 1, at: time, v)
  }

  public func set(_ value: Bool, at time: Double? = nil) throws { try set(value ? 1 : 0, at: time) }

  public func set(rgb value: SIMD3<Double>, at time: Double? = nil) throws {
    var v = OfxSwiftParamValue()
    v.doubles = (value.x, value.y, value.z, 0)
    try set(OfxSwiftParamValueKindDouble, 3, at: time, v)
  }

  public func set(rgba value: SIMD4<Double>, at time: Double? = nil) throws {
    var v = OfxSwiftParamValue()
    v.doubles = (value.x, value.y, value.z, value.w)
    try set(OfxSwiftParamValueKindDouble, 4, at: time, v)
  }

  public func set(_ value: String, at time: Double? = nil) throws {
    try value.withCString { s in
      var v = OfxSwiftParamValue()
      v.string = s
      try set(OfxSwiftParamValueKindString, 1, at: time, v)
    }
  }
}

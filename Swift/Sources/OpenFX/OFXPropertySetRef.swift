// Copyright OpenFX and contributors to the OpenFX project.
// SPDX-License-Identifier: BSD-3-Clause

/// A typed, throwing view of an `OfxPropertySetHandle`, accessed through an
/// `OfxPropertySuiteV1`.
///
/// This works with any property suite, so it is used by Swift plug-ins (with
/// the host's suite) and is also handy for exercising a Swift host's own suite.
public struct OFXPropertySetRef {
  public let handle: OfxPropertySetHandle
  public let suite: UnsafePointer<OfxPropertySuiteV1>

  public init(_ handle: OfxPropertySetHandle, suite: UnsafePointer<OfxPropertySuiteV1>) {
    self.handle = handle
    self.suite = suite
  }

  // MARK: Dimension

  public func dimension(_ name: String) throws -> Int {
    var count: Int32 = 0
    try OFXStatus.check(suite.pointee.propGetDimension(handle, name, &count))
    return Int(count)
  }

  public func reset(_ name: String) throws {
    try OFXStatus.check(suite.pointee.propReset(handle, name))
  }

  // MARK: Getters

  public func int(_ name: String, at index: Int = 0) throws -> Int {
    var v: Int32 = 0
    try OFXStatus.check(suite.pointee.propGetInt(handle, name, Int32(index), &v))
    return Int(v)
  }

  public func bool(_ name: String, at index: Int = 0) throws -> Bool {
    try int(name, at: index) != 0
  }

  public func double(_ name: String, at index: Int = 0) throws -> Double {
    var v: Double = 0
    try OFXStatus.check(suite.pointee.propGetDouble(handle, name, Int32(index), &v))
    return v
  }

  public func string(_ name: String, at index: Int = 0) throws -> String {
    var v: UnsafeMutablePointer<CChar>? = nil
    try OFXStatus.check(suite.pointee.propGetString(handle, name, Int32(index), &v))
    return v.map { String(cString: $0) } ?? ""
  }

  public func pointer(_ name: String, at index: Int = 0) throws -> UnsafeMutableRawPointer? {
    var v: UnsafeMutableRawPointer? = nil
    try OFXStatus.check(suite.pointee.propGetPointer(handle, name, Int32(index), &v))
    return v
  }

  public func ints(_ name: String) throws -> [Int] {
    let n = try dimension(name)
    if n == 0 { return [] }
    var v = [Int32](repeating: 0, count: n)
    try OFXStatus.check(suite.pointee.propGetIntN(handle, name, Int32(n), &v))
    return v.map(Int.init)
  }

  public func doubles(_ name: String) throws -> [Double] {
    let n = try dimension(name)
    if n == 0 { return [] }
    var v = [Double](repeating: 0, count: n)
    try OFXStatus.check(suite.pointee.propGetDoubleN(handle, name, Int32(n), &v))
    return v
  }

  public func strings(_ name: String) throws -> [String] {
    let n = try dimension(name)
    return try (0..<n).map { try string(name, at: $0) }
  }

  public func rectI(_ name: String) throws -> OfxRectI {
    var r = OfxRectI()
    try withUnsafeMutableBytes(of: &r) { raw in
      try OFXStatus.check(suite.pointee.propGetIntN(
        handle, name, 4, raw.baseAddress!.assumingMemoryBound(to: Int32.self)))
    }
    return r
  }

  public func rectD(_ name: String) throws -> OfxRectD {
    var r = OfxRectD()
    try withUnsafeMutableBytes(of: &r) { raw in
      try OFXStatus.check(suite.pointee.propGetDoubleN(
        handle, name, 4, raw.baseAddress!.assumingMemoryBound(to: Double.self)))
    }
    return r
  }

  public func pointD(_ name: String) throws -> OfxPointD {
    OfxPointD(x: try double(name, at: 0), y: try double(name, at: 1))
  }

  // MARK: Setters

  public func set(_ name: String, _ value: Int, at index: Int = 0) throws {
    try OFXStatus.check(suite.pointee.propSetInt(handle, name, Int32(index), Int32(value)))
  }

  public func set(_ name: String, _ value: Bool, at index: Int = 0) throws {
    try set(name, value ? 1 : 0, at: index)
  }

  public func set(_ name: String, _ value: Double, at index: Int = 0) throws {
    try OFXStatus.check(suite.pointee.propSetDouble(handle, name, Int32(index), value))
  }

  public func set(_ name: String, _ value: String, at index: Int = 0) throws {
    try OFXStatus.check(suite.pointee.propSetString(handle, name, Int32(index), value))
  }

  public func set(_ name: String, pointer value: UnsafeMutableRawPointer?, at index: Int = 0) throws {
    try OFXStatus.check(suite.pointee.propSetPointer(handle, name, Int32(index), value))
  }

  public func set(_ name: String, ints values: [Int]) throws {
    let v = values.map { Int32($0) }
    try OFXStatus.check(suite.pointee.propSetIntN(handle, name, Int32(v.count), v))
  }

  public func set(_ name: String, doubles values: [Double]) throws {
    try OFXStatus.check(suite.pointee.propSetDoubleN(handle, name, Int32(values.count), values))
  }

  /// Sets each string by index, which also works on hosts that grow variable
  /// dimension properties one element at a time.
  public func set(_ name: String, strings values: [String]) throws {
    for (i, s) in values.enumerated() { try set(name, s, at: i) }
  }

  public func set(_ name: String, rect r: OfxRectI) throws {
    try set(name, ints: [Int(r.x1), Int(r.y1), Int(r.x2), Int(r.y2)])
  }

  public func set(_ name: String, rect r: OfxRectD) throws {
    try set(name, doubles: [r.x1, r.y1, r.x2, r.y2])
  }
}

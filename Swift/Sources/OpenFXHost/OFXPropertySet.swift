// Copyright OpenFX and contributors to the OpenFX project.
// SPDX-License-Identifier: BSD-3-Clause

import Foundation
import OpenFX

/// A host-side property value.
public enum OFXPropertyValue: Equatable {
  case int([Int])
  case double([Double])
  case string([String])
  case pointer([UnsafeMutableRawPointer?])

  public var count: Int {
    switch self {
    case .int(let v): return v.count
    case .double(let v): return v.count
    case .string(let v): return v.count
    case .pointer(let v): return v.count
    }
  }
}

/// The host's storage behind an `OfxPropertySetHandle`.
///
/// The handle handed to plug-ins is the unretained address of this object, so
/// whoever creates a property set must keep it alive for as long as plug-ins
/// may use the handle (effects, clips, parameters and images do this).
///
/// Unknown properties are created on first `set`, which keeps the host
/// tolerant of plug-ins setting properties it does not know about.
public class OFXPropertySet {
  enum Storage {
    case int([Int32])
    case double([Double])
    // Strings are kept as C strings so `propGetString` can return stable pointers.
    case string([UnsafeMutablePointer<CChar>])
    case pointer([UnsafeMutableRawPointer?])
  }

  final class Property {
    var storage: Storage
    let readOnly: Bool

    init(_ storage: Storage, readOnly: Bool) {
      self.storage = storage
      self.readOnly = readOnly
    }

    deinit { Property.free(storage) }

    static func free(_ storage: Storage) {
      if case .string(let ptrs) = storage { ptrs.forEach { Foundation.free($0) } }
    }

    var count: Int {
      switch storage {
      case .int(let v): return v.count
      case .double(let v): return v.count
      case .string(let v): return v.count
      case .pointer(let v): return v.count
      }
    }

    func replace(_ newStorage: Storage) {
      let old = storage
      storage = newStorage
      Property.free(old)
    }
  }

  private var properties: [String: Property] = [:]
  private let lock = NSRecursiveLock()

  /// A short label used in diagnostics.
  public var debugName: String

  public init(debugName: String = "") {
    self.debugName = debugName
  }

  /// The handle to give to plug-ins.
  public var handle: OfxPropertySetHandle {
    OpaquePointer(Unmanaged.passUnretained(self).toOpaque())
  }

  /// Recovers the property set behind a handle created by `handle`.
  public static func from(_ handle: OfxPropertySetHandle?) -> OFXPropertySet? {
    guard let handle else { return nil }
    return Unmanaged<OFXPropertySet>.fromOpaque(UnsafeRawPointer(handle)).takeUnretainedValue()
  }

  // MARK: Swift API

  /// Defines (or redefines) a property with a value.
  public func define(_ name: String, _ value: OFXPropertyValue, readOnly: Bool = false) {
    lock.locked { properties[name] = Property(Self.storage(for: value), readOnly: readOnly) }
  }

  public func contains(_ name: String) -> Bool {
    lock.locked { properties[name] != nil }
  }

  public var names: [String] {
    lock.locked { Array(properties.keys).sorted() }
  }

  public subscript(name: String) -> OFXPropertyValue? {
    get {
      lock.locked {
        guard let p = properties[name] else { return nil }
        return Self.value(of: p.storage)
      }
    }
    set {
      lock.locked {
        guard let newValue else { properties[name] = nil; return }
        if let p = properties[name] {
          p.replace(Self.storage(for: newValue))
        } else {
          properties[name] = Property(Self.storage(for: newValue), readOnly: false)
        }
      }
    }
  }

  public func set(_ name: String, _ v: Int) { self[name] = .int([v]) }
  public func set(_ name: String, _ v: Bool) { self[name] = .int([v ? 1 : 0]) }
  public func set(_ name: String, _ v: Double) { self[name] = .double([v]) }
  public func set(_ name: String, _ v: String) { self[name] = .string([v]) }
  public func set(_ name: String, pointer v: UnsafeMutableRawPointer?) { self[name] = .pointer([v]) }
  public func set(_ name: String, ints v: [Int]) { self[name] = .int(v) }
  public func set(_ name: String, doubles v: [Double]) { self[name] = .double(v) }
  public func set(_ name: String, strings v: [String]) { self[name] = .string(v) }
  public func set(_ name: String, rect r: OfxRectI) {
    self[name] = .int([Int(r.x1), Int(r.y1), Int(r.x2), Int(r.y2)])
  }
  public func set(_ name: String, rect r: OfxRectD) {
    self[name] = .double([r.x1, r.y1, r.x2, r.y2])
  }

  public func int(_ name: String, at i: Int = 0) -> Int? {
    if case .int(let v)? = self[name], i < v.count { return v[i] }
    return nil
  }
  public func bool(_ name: String, at i: Int = 0) -> Bool? { int(name, at: i).map { $0 != 0 } }
  public func double(_ name: String, at i: Int = 0) -> Double? {
    if case .double(let v)? = self[name], i < v.count { return v[i] }
    return nil
  }
  public func string(_ name: String, at i: Int = 0) -> String? {
    if case .string(let v)? = self[name], i < v.count { return v[i] }
    return nil
  }
  public func pointer(_ name: String, at i: Int = 0) -> UnsafeMutableRawPointer? {
    if case .pointer(let v)? = self[name], i < v.count { return v[i] }
    return nil
  }
  public func ints(_ name: String) -> [Int] {
    if case .int(let v)? = self[name] { return v }
    return []
  }
  public func doubles(_ name: String) -> [Double] {
    if case .double(let v)? = self[name] { return v }
    return []
  }
  public func strings(_ name: String) -> [String] {
    if case .string(let v)? = self[name] { return v }
    return []
  }
  public func rectI(_ name: String) -> OfxRectI? {
    let v = ints(name)
    guard v.count == 4 else { return nil }
    return OfxRectI(x1: Int32(v[0]), y1: Int32(v[1]), x2: Int32(v[2]), y2: Int32(v[3]))
  }
  public func rectD(_ name: String) -> OfxRectD? {
    let v = doubles(name)
    guard v.count == 4 else { return nil }
    return OfxRectD(x1: v[0], y1: v[1], x2: v[2], y2: v[3])
  }

  /// Copies every property of `other` into this set (overwriting same-named ones).
  public func copyProperties(from other: OFXPropertySet, excluding excluded: Set<String> = []) {
    let snapshot: [(String, OFXPropertyValue, Bool)] = other.lock.locked {
      other.properties.compactMap { name, p in
        excluded.contains(name) ? nil : (name, Self.value(of: p.storage), p.readOnly)
      }
    }
    lock.locked {
      for (name, value, readOnly) in snapshot {
        properties[name] = Property(Self.storage(for: value), readOnly: readOnly)
      }
    }
  }

  // MARK: Conversions

  static func storage(for value: OFXPropertyValue) -> Storage {
    switch value {
    case .int(let v): return .int(v.map { Int32(truncatingIfNeeded: $0) })
    case .double(let v): return .double(v)
    case .string(let v): return .string(v.map { strdup($0)! })
    case .pointer(let v): return .pointer(v)
    }
  }

  static func value(of storage: Storage) -> OFXPropertyValue {
    switch storage {
    case .int(let v): return .int(v.map(Int.init))
    case .double(let v): return .double(v)
    case .string(let v): return .string(v.map { String(cString: $0) })
    case .pointer(let v): return .pointer(v)
    }
  }

  // MARK: Property suite implementation

  enum Kind { case int, double, string, pointer }

  private func lookup(_ cName: UnsafePointer<CChar>?) -> (String, Property?)? {
    guard let cName else { return nil }
    let name = String(cString: cName)
    return (name, properties[name])
  }

  func suiteSet(_ cName: UnsafePointer<CChar>?, index: Int32, count: Int32,
                kind: Kind, write: (inout Storage, Int) -> Void) -> OfxStatus {
    lock.locked {
      guard let (name, existing) = lookup(cName) else { return kOfxStatErrBadHandle }
      guard index >= 0, count >= 0 else { return kOfxStatErrBadIndex }
      let property: Property
      if let existing {
        if existing.readOnly { return kOfxStatErrValue }
        property = existing
      } else {
        property = Property(Self.empty(kind), readOnly: false)
        properties[name] = property
      }
      guard Self.kind(of: property.storage) == kind else { return kOfxStatErrValue }
      // Grow the property so that [index, index + count) is valid.
      let needed = Int(index) + Int(count)
      var storage = property.storage
      property.storage = Self.empty(kind) // avoid freeing strings we are about to keep
      Self.grow(&storage, to: needed)
      write(&storage, Int(index))
      property.storage = storage
      return kOfxStatOK
    }
  }

  func suiteGet(_ cName: UnsafePointer<CChar>?, index: Int32, count: Int32, kind: Kind,
                read: (Storage, Int) -> Void) -> OfxStatus {
    lock.locked {
      guard let (_, property) = lookup(cName) else { return kOfxStatErrBadHandle }
      guard let property else { return kOfxStatErrUnknown }
      guard Self.kind(of: property.storage) == kind else { return kOfxStatErrValue }
      guard index >= 0, count >= 0, Int(index) + Int(count) <= property.count else {
        return kOfxStatErrBadIndex
      }
      read(property.storage, Int(index))
      return kOfxStatOK
    }
  }

  func suiteReset(_ cName: UnsafePointer<CChar>?) -> OfxStatus {
    lock.locked {
      guard let (_, property) = lookup(cName) else { return kOfxStatErrBadHandle }
      guard property != nil else { return kOfxStatErrUnknown }
      // This host does not track per-property defaults; resetting is a no-op.
      return kOfxStatOK
    }
  }

  func suiteDimension(_ cName: UnsafePointer<CChar>?, _ count: UnsafeMutablePointer<Int32>?) -> OfxStatus {
    lock.locked {
      guard let (_, property) = lookup(cName) else { return kOfxStatErrBadHandle }
      guard let property else { return kOfxStatErrUnknown }
      count?.pointee = Int32(property.count)
      return kOfxStatOK
    }
  }

  static func kind(of storage: Storage) -> Kind {
    switch storage {
    case .int: return .int
    case .double: return .double
    case .string: return .string
    case .pointer: return .pointer
    }
  }

  static func empty(_ kind: Kind) -> Storage {
    switch kind {
    case .int: return .int([])
    case .double: return .double([])
    case .string: return .string([])
    case .pointer: return .pointer([])
    }
  }

  static func grow(_ storage: inout Storage, to count: Int) {
    switch storage {
    case .int(var v):
      if v.count < count { v += Array(repeating: 0, count: count - v.count) }
      storage = .int(v)
    case .double(var v):
      if v.count < count { v += Array(repeating: 0, count: count - v.count) }
      storage = .double(v)
    case .string(var v):
      while v.count < count { v.append(strdup("")!) }
      storage = .string(v)
    case .pointer(var v):
      if v.count < count { v += Array(repeating: nil, count: count - v.count) }
      storage = .pointer(v)
    }
  }
}

extension NSRecursiveLock {
  @inline(__always)
  func locked<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}

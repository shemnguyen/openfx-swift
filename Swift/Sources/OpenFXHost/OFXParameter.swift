// Copyright OpenFX and contributors to the OpenFX project.
// SPDX-License-Identifier: BSD-3-Clause

import Foundation
import OpenFX

/// A parameter value as seen by the host.
public enum OFXParameterValue: Equatable, Sendable, CustomStringConvertible {
  case none
  case int([Int])
  case double([Double])
  case string(String)

  public static func bool(_ b: Bool) -> OFXParameterValue { .int([b ? 1 : 0]) }
  public static func int(_ v: Int) -> OFXParameterValue { .int([v]) }
  public static func double(_ v: Double) -> OFXParameterValue { .double([v]) }

  public var ints: [Int] { if case .int(let v) = self { return v } else { return [] } }
  public var doubles: [Double] { if case .double(let v) = self { return v } else { return [] } }
  public var stringValue: String? { if case .string(let v) = self { return v } else { return nil } }
  public var boolValue: Bool { ints.first.map { $0 != 0 } ?? false }

  public var description: String {
    switch self {
    case .none: return "none"
    case .int(let v): return v.count == 1 ? "\(v[0])" : "\(v)"
    case .double(let v): return v.count == 1 ? "\(v[0])" : "\(v)"
    case .string(let v): return "\"\(v)\""
    }
  }
}

/// A parameter descriptor or instance. Its handle is the `OfxParamHandle` given to plug-ins.
public final class OFXParameter: @unchecked Sendable {
  public let name: String
  public let type: OFXParamType
  public let properties: OFXPropertySet
  public private(set) weak var parameterSet: OFXParameterSet?

  private let lock = NSRecursiveLock()
  private var constant: OFXParameterValue
  private var keys: [(time: Double, value: OFXParameterValue)] = []
  private var cString: UnsafeMutablePointer<CChar>?
  private var cStringSource: String?

  init(name: String, type: OFXParamType, properties: OFXPropertySet, parameterSet: OFXParameterSet) {
    self.name = name
    self.type = type
    self.properties = properties
    self.parameterSet = parameterSet
    self.constant = .none
    self.constant = defaultValue
  }

  deinit { free(cString) }

  public var handle: OfxParamHandle { OpaquePointer(Unmanaged.passUnretained(self).toOpaque()) }

  static func from(_ handle: OfxParamHandle?) -> OFXParameter? {
    guard let handle else { return nil }
    return Unmanaged<OFXParameter>.fromOpaque(UnsafeRawPointer(handle)).takeUnretainedValue()
  }

  // MARK: Descriptive properties

  public var label: String { properties.string(kOfxPropLabel).flatMap { $0.isEmpty ? nil : $0 } ?? name }
  public var hint: String { properties.string(kOfxParamPropHint) ?? "" }
  /// Name of the enclosing group parameter, or "" at the top level.
  public var parent: String { properties.string(kOfxParamPropParent) ?? "" }
  public var isSecret: Bool { properties.bool(kOfxParamPropSecret) ?? false }
  public var isEnabled: Bool { properties.bool(kOfxParamPropEnabled) ?? true }
  public var animates: Bool { properties.bool(kOfxParamPropAnimates) ?? false }
  public var choiceOptions: [String] { properties.strings(kOfxParamPropChoiceOption) }
  /// For `strChoice` parameters, the string values corresponding to `choiceOptions`.
  public var choiceEnums: [String] { properties.strings(kOfxParamPropChoiceEnum) }
  public var dimensionLabels: [String] { properties.strings(kOfxParamPropDimensionLabel) }
  public var minimum: OFXParameterValue { value(ofProperty: kOfxParamPropMin) }
  public var maximum: OFXParameterValue { value(ofProperty: kOfxParamPropMax) }
  public var displayMinimum: OFXParameterValue { value(ofProperty: kOfxParamPropDisplayMin) }
  public var displayMaximum: OFXParameterValue { value(ofProperty: kOfxParamPropDisplayMax) }

  /// The plug-in's declared default (`kOfxParamPropDefault`).
  public var defaultValue: OFXParameterValue { value(ofProperty: kOfxParamPropDefault) }

  /// The default in canonical coordinates for a project of `size`.
  ///
  /// Spatial double parameters may declare their default in normalised
  /// coordinates (`kOfxParamPropDefaultCoordinateSystem`); the host scales those
  /// by the project size. Other parameters return `defaultValue` unchanged.
  func canonicalDefault(projectSize size: (width: Double, height: Double)) -> OFXParameterValue {
    guard properties.string(kOfxParamPropDefaultCoordinateSystem) == kOfxParamCoordinatesNormalised,
          case .double(let v) = defaultValue else { return defaultValue }
    let scale: [Double]
    switch properties.string(kOfxParamPropDoubleType) {
    case kOfxParamDoubleTypeX, kOfxParamDoubleTypeXAbsolute: scale = [size.width]
    case kOfxParamDoubleTypeY, kOfxParamDoubleTypeYAbsolute: scale = [size.height]
    case kOfxParamDoubleTypeXY, kOfxParamDoubleTypeXYAbsolute: scale = [size.width, size.height]
    default: return defaultValue
    }
    return .double(zip(v, scale).map { $0 * $1 } + v.dropFirst(scale.count))
  }

  /// Whether the parameter carries a value (groups, pages and buttons do not).
  public var hasValue: Bool { type.valueLayout.kind != OfxSwiftParamValueKindNone }

  private func value(ofProperty name: String) -> OFXParameterValue {
    let (kind, count) = type.valueLayout
    switch kind {
    case OfxSwiftParamValueKindInt:
      return .int(Self.padded(properties.ints(name), count))
    case OfxSwiftParamValueKindDouble:
      // Some plug-ins set integer defaults on double parameters; accept either.
      let d = properties.doubles(name)
      return .double(Self.padded(d.isEmpty ? properties.ints(name).map(Double.init) : d, count))
    case OfxSwiftParamValueKindString:
      return .string(properties.string(name) ?? "")
    default:
      return .none
    }
  }

  private static func padded<T: Numeric>(_ v: [T], _ n: Int) -> [T] {
    v.count >= n ? Array(v.prefix(n)) : v + Array(repeating: 0, count: n - v.count)
  }

  // MARK: Values

  /// The value at `time`, or the current value when `time` is nil or there are no keyframes.
  public func value(at time: Double? = nil) -> OFXParameterValue {
    lock.locked {
      guard let firstKey = keys.first else { return constant }
      return interpolate(at: time ?? currentTime ?? firstKey.time)
    }
  }

  /// Sets the value. With a time, sets (or replaces) a keyframe at that time.
  ///
  /// This only stores the value; use `OFXImageEffectInstance.setValue(_:for:)`
  /// to also notify the plug-in.
  public func setValue(_ newValue: OFXParameterValue, at time: Double? = nil) {
    let v = coerce(newValue)
    lock.locked {
      if let time {
        if let i = keys.firstIndex(where: { $0.time == time }) {
          keys[i].value = v
        } else {
          keys.append((time, v))
          keys.sort { $0.time < $1.time }
        }
      } else if !keys.isEmpty, let t = currentTime {
        // Animated parameter: an untimed set edits the key at the current time.
        setValue(v, at: t)
      } else {
        constant = v
      }
    }
  }

  public var keyframeTimes: [Double] { lock.locked { keys.map(\.time) } }

  /// The keyframes, in time order.
  public var keyframes: [(time: Double, value: OFXParameterValue)] { lock.locked { keys } }

  /// The value used when the parameter has no keyframes.
  public var staticValue: OFXParameterValue { lock.locked { constant } }

  /// Replaces the whole value state at once, e.g. to mirror a parameter that lives in another process.
  public func restore(staticValue: OFXParameterValue, keyframes: [(time: Double, value: OFXParameterValue)]) {
    let value = coerce(staticValue)
    let keys = keyframes.map { (time: $0.time, value: coerce($0.value)) }.sorted { $0.time < $1.time }
    lock.locked {
      constant = value
      self.keys = keys
    }
  }

  public func deleteKeyframe(at time: Double) -> Bool {
    lock.locked {
      guard let i = keys.firstIndex(where: { $0.time == time }) else { return false }
      let removed = keys.remove(at: i)
      if keys.isEmpty { constant = removed.value }
      return true
    }
  }

  public func deleteAllKeyframes() {
    lock.locked {
      if let t = currentTime, !keys.isEmpty { constant = interpolate(at: t) }
      keys.removeAll()
    }
  }

  private var currentTime: Double? { parameterSet?.currentTime }

  /// Makes `v` match this parameter's layout (e.g. accepts `.int` for a double param).
  private func coerce(_ v: OFXParameterValue) -> OFXParameterValue {
    let (kind, count) = type.valueLayout
    switch (kind, v) {
    case (OfxSwiftParamValueKindInt, .int(let a)): return .int(Self.padded(a, count))
    case (OfxSwiftParamValueKindInt, .double(let a)): return .int(Self.padded(a.map { Int($0.rounded()) }, count))
    case (OfxSwiftParamValueKindDouble, .double(let a)): return .double(Self.padded(a, count))
    case (OfxSwiftParamValueKindDouble, .int(let a)): return .double(Self.padded(a.map(Double.init), count))
    case (OfxSwiftParamValueKindString, .string): return v
    case (OfxSwiftParamValueKindString, _): return .string(v.description)
    case (OfxSwiftParamValueKindNone, _): return .none
    default: return v
    }
  }

  private func interpolate(at t: Double) -> OFXParameterValue {
    guard let first = keys.first, let last = keys.last else { return constant }
    if t <= first.time { return first.value }
    if t >= last.time { return last.value }
    let i = keys.lastIndex(where: { $0.time <= t })!
    let a = keys[i], b = keys[i + 1]
    let f = (t - a.time) / (b.time - a.time)
    switch (a.value, b.value) {
    case (.double(let x), .double(let y)):
      return .double(zip(x, y).map { $0 + ($1 - $0) * f })
    case (.int(let x), .int(let y)) where [.integer, .integer2D, .integer3D].contains(type):
      return .int(zip(x, y).map { Int((Double($0) + Double($1 - $0) * f).rounded()) })
    default:
      return a.value // step interpolation for booleans, choices and strings
    }
  }

  func derivative(at t: Double) -> [Double] {
    lock.locked {
      let count = type.valueLayout.count
      guard keys.count >= 2 else { return Array(repeating: 0, count: count) }
      let h = 1e-3
      let a = interpolate(at: t - h).doubles, b = interpolate(at: t + h).doubles
      return zip(a, b).map { ($1 - $0) / (2 * h) }
    }
  }

  func integral(from t1: Double, to t2: Double) -> [Double] {
    lock.locked {
      let count = type.valueLayout.count
      if keys.count < 2 {
        let v = (keys.first?.value ?? constant).doubles
        return Self.padded(v, count).map { $0 * (t2 - t1) }
      }
      // Values are piecewise linear between keys, so trapezoids over the key times are exact.
      let lo = min(t1, t2), hi = max(t1, t2), sign: Double = t2 >= t1 ? 1 : -1
      let times = [lo] + keys.map(\.time).filter { $0 > lo && $0 < hi } + [hi]
      var sum = [Double](repeating: 0, count: count)
      for (ta, tb) in zip(times, times.dropFirst()) {
        let va = Self.padded(interpolate(at: ta).doubles, count)
        let vb = Self.padded(interpolate(at: tb).doubles, count)
        for c in 0..<count { sum[c] += (va[c] + vb[c]) / 2 * (tb - ta) }
      }
      return sum.map { $0 * sign }
    }
  }

  // MARK: Variadic suite bridge

  func fill(_ out: inout OfxSwiftParamValue, with value: OFXParameterValue) {
    switch value {
    case .int(let v):
      for (i, x) in v.prefix(4).enumerated() { withUnsafeMutableBytes(of: &out.ints) { $0.storeBytes(of: Int32(truncatingIfNeeded: x), toByteOffset: i * 4, as: Int32.self) } }
    case .double(let v):
      for (i, x) in v.prefix(4).enumerated() { withUnsafeMutableBytes(of: &out.doubles) { $0.storeBytes(of: x, toByteOffset: i * 8, as: Double.self) } }
    case .string(let s):
      lock.locked {
        if cStringSource != s {
          free(cString)
          cString = strdup(s)
          cStringSource = s
        }
        out.string = UnsafePointer(cString)
      }
    case .none:
      break
    }
  }

  func value(from v: OfxSwiftParamValue) -> OFXParameterValue {
    let (kind, count) = type.valueLayout
    var v = v
    switch kind {
    case OfxSwiftParamValueKindInt:
      return .int(withUnsafeBytes(of: &v.ints) { Array($0.bindMemory(to: Int32.self).prefix(count)) }.map(Int.init))
    case OfxSwiftParamValueKindDouble:
      return .double(withUnsafeBytes(of: &v.doubles) { Array($0.bindMemory(to: Double.self).prefix(count)) })
    case OfxSwiftParamValueKindString:
      return .string(v.string.map { String(cString: $0) } ?? "")
    default:
      return .none
    }
  }

  // MARK: Descriptor defaults

  /// The properties a freshly defined parameter of `type` starts with.
  static func defaultProperties(type: OFXParamType, name: String) -> OFXPropertySet {
    let p = OFXPropertySet(debugName: "param \(name)")
    p.set(kOfxPropType, kOfxTypeParameter)
    p.set(kOfxPropName, name)
    p.set(kOfxPropLabel, name)
    p.set(kOfxPropShortLabel, name)
    p.set(kOfxPropLongLabel, name)
    p.define(kOfxParamPropType, .string([type.rawValue]), readOnly: true)
    p.set(kOfxParamPropSecret, false)
    p.set(kOfxParamPropHint, "")
    p.set(kOfxParamPropScriptName, name)
    p.set(kOfxParamPropParent, "")
    p.set(kOfxParamPropEnabled, true)
    p.set(kOfxParamPropDataPtr, pointer: nil)
    p.set(kOfxParamPropInteractV1, pointer: nil)
    p.set(kOfxParamPropInteractSize, doubles: [0, 0])
    p.set(kOfxParamPropInteractSizeAspect, 1.0)
    p.set(kOfxParamPropInteractMinimumSize, ints: [10, 10])
    p.set(kOfxParamPropInteractPreferedSize, ints: [10, 10])
    p.set(kOfxPropIcon, strings: ["", ""])

    let (kind, count) = type.valueLayout
    if kind != OfxSwiftParamValueKindNone {
      let numeric = kind != OfxSwiftParamValueKindString
      let animates = numeric && type != .boolean && type != .choice
      p.set(kOfxParamPropAnimates, animates)
      p.define(kOfxParamPropIsAnimating, .int([0]), readOnly: true)
      p.define(kOfxParamPropIsAutoKeying, .int([0]), readOnly: true)
      p.set(kOfxParamPropPersistant, true)
      p.set(kOfxParamPropEvaluateOnChange, true)
      p.set(kOfxParamPropPluginMayWrite, false)
      p.set(kOfxParamPropCanUndo, true)
      p.set(kOfxParamPropCacheInvalidation, kOfxParamInvalidateValueChange)
    }

    switch kind {
    case OfxSwiftParamValueKindInt:
      p.set(kOfxParamPropDefault, ints: Array(repeating: 0, count: count))
      if type == .integer || type == .integer2D || type == .integer3D {
        p.set(kOfxParamPropMin, ints: Array(repeating: Int(Int32.min), count: count))
        p.set(kOfxParamPropMax, ints: Array(repeating: Int(Int32.max), count: count))
        p.set(kOfxParamPropDisplayMin, ints: Array(repeating: Int(Int32.min), count: count))
        p.set(kOfxParamPropDisplayMax, ints: Array(repeating: Int(Int32.max), count: count))
      }
    case OfxSwiftParamValueKindDouble:
      p.set(kOfxParamPropDefault, doubles: Array(repeating: 0, count: count))
      let lo = type == .rgb || type == .rgba ? 0 : -Double.greatestFiniteMagnitude
      let hi = type == .rgb || type == .rgba ? 1 : Double.greatestFiniteMagnitude
      p.set(kOfxParamPropMin, doubles: Array(repeating: lo, count: count))
      p.set(kOfxParamPropMax, doubles: Array(repeating: hi, count: count))
      p.set(kOfxParamPropDisplayMin, doubles: Array(repeating: lo, count: count))
      p.set(kOfxParamPropDisplayMax, doubles: Array(repeating: hi, count: count))
      p.set(kOfxParamPropIncrement, 1.0)
      p.set(kOfxParamPropDigits, 2)
      if type != .rgb && type != .rgba {
        p.set(kOfxParamPropDoubleType, kOfxParamDoubleTypePlain)
        p.set(kOfxParamPropDefaultCoordinateSystem, kOfxParamCoordinatesCanonical)
        p.set(kOfxParamPropShowTimeMarker, false)
      }
    case OfxSwiftParamValueKindString:
      p.set(kOfxParamPropDefault, "")
    default:
      break
    }

    switch type {
    case .double2D, .integer2D: p.set(kOfxParamPropDimensionLabel, strings: ["x", "y"])
    case .double3D, .integer3D: p.set(kOfxParamPropDimensionLabel, strings: ["x", "y", "z"])
    case .rgb: p.set(kOfxParamPropDimensionLabel, strings: ["r", "g", "b"])
    case .rgba: p.set(kOfxParamPropDimensionLabel, strings: ["r", "g", "b", "a"])
    case .choice:
      p[kOfxParamPropChoiceOption] = .string([])
      p[kOfxParamPropChoiceOrder] = .int([])
    case .strChoice:
      p[kOfxParamPropChoiceOption] = .string([])
      p[kOfxParamPropChoiceEnum] = .string([])
    case .string:
      p.set(kOfxParamPropStringMode, kOfxParamStringIsSingleLine)
      p.set(kOfxParamPropStringFilePathExists, true)
    case .custom:
      p.set(kOfxParamPropCustomInterpCallbackV1, pointer: nil)
    case .group:
      p.set(kOfxParamPropGroupOpen, true)
    case .page:
      p[kOfxParamPropPageChild] = .string([])
    default:
      break
    }
    return p
  }
}

/// The parameters of an effect descriptor or instance. Its handle is the `OfxParamSetHandle`.
public final class OFXParameterSet {
  public let properties = OFXPropertySet(debugName: "param set")
  public private(set) var parameters: [OFXParameter] = []
  private var byName: [String: OFXParameter] = [:]
  public internal(set) weak var effect: OFXImageEffect?
  private let timeSource: (() -> Double?)?

  init(effect: OFXImageEffect?) {
    self.effect = effect
    self.timeSource = nil
  }

  /// A parameter set that is not attached to an effect, such as a host-side mirror
  /// of a plug-in running in another process. `currentTime` supplies the time
  /// untimed reads of animated parameters use.
  public init(currentTime: @escaping () -> Double? = { nil }) {
    self.effect = nil
    self.timeSource = currentTime
  }

  /// The time untimed reads of animated parameters use.
  var currentTime: Double? { effect?.currentTime ?? timeSource?() }

  /// Adds a parameter with the given (already complete) properties, starting at its default value.
  @discardableResult
  public func addParameter(name: String, type: OFXParamType, properties: OFXPropertySet) -> OFXParameter {
    let param = OFXParameter(name: name, type: type, properties: properties, parameterSet: self)
    parameters.append(param)
    byName[name] = param
    return param
  }

  public var handle: OfxParamSetHandle { OpaquePointer(Unmanaged.passUnretained(self).toOpaque()) }

  static func from(_ handle: OfxParamSetHandle?) -> OFXParameterSet? {
    guard let handle else { return nil }
    return Unmanaged<OFXParameterSet>.fromOpaque(UnsafeRawPointer(handle)).takeUnretainedValue()
  }

  public subscript(name: String) -> OFXParameter? { byName[name] }

  /// The parameters with values, in definition order, excluding secret ones.
  public var visibleValueParameters: [OFXParameter] {
    parameters.filter { $0.hasValue && !$0.isSecret }
  }

  @discardableResult
  func define(type: OFXParamType, name: String) throws -> OFXParameter {
    guard byName[name] == nil else { throw OFXStatus.errExists }
    let param = OFXParameter(name: name, type: type,
                             properties: OFXParameter.defaultProperties(type: type, name: name),
                             parameterSet: self)
    parameters.append(param)
    byName[name] = param
    return param
  }

  /// Instantiates a copy of `descriptor`'s parameters, each starting at its default value.
  func instantiate(from descriptor: OFXParameterSet, projectSize: (width: Double, height: Double)) {
    properties.copyProperties(from: descriptor.properties)
    for d in descriptor.parameters {
      let props = OFXPropertySet(debugName: "param \(d.name)")
      props.copyProperties(from: d.properties)
      let param = OFXParameter(name: d.name, type: d.type, properties: props, parameterSet: self)
      param.setValue(param.canonicalDefault(projectSize: projectSize))
      parameters.append(param)
      byName[d.name] = param
    }
  }
}

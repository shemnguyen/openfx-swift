// Copyright OpenFX and contributors to the OpenFX project.
// SPDX-License-Identifier: BSD-3-Clause

extension OfxRectI {
  public var width: Int { Int(x2) - Int(x1) }
  public var height: Int { Int(y2) - Int(y1) }
  public var isEmpty: Bool { x2 <= x1 || y2 <= y1 }

  public func intersection(_ other: OfxRectI) -> OfxRectI {
    let r = OfxRectI(x1: max(x1, other.x1), y1: max(y1, other.y1),
                     x2: min(x2, other.x2), y2: min(y2, other.y2))
    return r.isEmpty ? OfxRectI(x1: 0, y1: 0, x2: 0, y2: 0) : r
  }

  public func contains(_ other: OfxRectI) -> Bool {
    other.x1 >= x1 && other.y1 >= y1 && other.x2 <= x2 && other.y2 <= y2
  }

  public func isEqual(to other: OfxRectI) -> Bool {
    x1 == other.x1 && y1 == other.y1 && x2 == other.x2 && y2 == other.y2
  }

  public var asDouble: OfxRectD {
    OfxRectD(x1: Double(x1), y1: Double(y1), x2: Double(x2), y2: Double(y2))
  }
}

extension OfxRectD {
  public var width: Double { x2 - x1 }
  public var height: Double { y2 - y1 }
  public var isEmpty: Bool { !(x2 > x1) || !(y2 > y1) }

  public func intersection(_ other: OfxRectD) -> OfxRectD {
    let r = OfxRectD(x1: max(x1, other.x1), y1: max(y1, other.y1),
                     x2: min(x2, other.x2), y2: min(y2, other.y2))
    return r.isEmpty ? OfxRectD(x1: 0, y1: 0, x2: 0, y2: 0) : r
  }

  public func union(_ other: OfxRectD) -> OfxRectD {
    if isEmpty { return other }
    if other.isEmpty { return self }
    return OfxRectD(x1: min(x1, other.x1), y1: min(y1, other.y1),
                    x2: max(x2, other.x2), y2: max(y2, other.y2))
  }

  /// The smallest pixel rectangle containing this rectangle, clamped to the `Int32` range.
  public var enclosingRectI: OfxRectI {
    func clamp(_ v: Double) -> Int32 {
      if v.isNaN { return 0 }
      return Int32(max(Double(Int32.min), min(Double(Int32.max), v)))
    }
    return OfxRectI(x1: clamp(x1.rounded(.down)), y1: clamp(y1.rounded(.down)),
                    x2: clamp(x2.rounded(.up)), y2: clamp(y2.rounded(.up)))
  }
}

import Foundation

public enum EstimateRangeError: Error, Equatable, Sendable {
    case nonFinite
    case negative
    case unordered
}

public struct EstimateRange: Codable, Equatable, Sendable {
    public let low: Double
    public let likely: Double
    public let high: Double

    public init(low: Double, likely: Double, high: Double) throws {
        guard low.isFinite, likely.isFinite, high.isFinite else {
            throw EstimateRangeError.nonFinite
        }
        guard low >= 0, likely >= 0, high >= 0 else {
            throw EstimateRangeError.negative
        }
        guard low <= likely, likely <= high else {
            throw EstimateRangeError.unordered
        }
        self.low = low
        self.likely = likely
        self.high = high
    }

    public static func point(_ value: Double) throws -> EstimateRange {
        try EstimateRange(low: value, likely: value, high: value)
    }

    public func scaled(by factor: Double) throws -> EstimateRange {
        guard factor.isFinite else { throw EstimateRangeError.nonFinite }
        guard factor >= 0 else { throw EstimateRangeError.negative }
        return try EstimateRange(
            low: low * factor,
            likely: likely * factor,
            high: high * factor
        )
    }

    public func adding(_ other: EstimateRange) throws -> EstimateRange {
        try EstimateRange(
            low: low + other.low,
            likely: likely + other.likely,
            high: high + other.high
        )
    }

    public static func sum<S: Sequence>(_ ranges: S) throws -> EstimateRange where S.Element == EstimateRange {
        try ranges.reduce(EstimateRange(low: 0, likely: 0, high: 0)) { partial, range in
            try partial.adding(range)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case low
        case likely
        case high
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            low: container.decode(Double.self, forKey: .low),
            likely: container.decode(Double.self, forKey: .likely),
            high: container.decode(Double.self, forKey: .high)
        )
    }
}

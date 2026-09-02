import Foundation

enum ToolSchemaValidator {
    static func validate(_ value: JSONValue, against schema: JSONSchemaNode) throws {
        try validate(value, against: schema, path: "$")
    }

    private static func validate(
        _ value: JSONValue,
        against schema: JSONSchemaNode,
        path: String
    ) throws {
        switch schema {
        case .object(let properties, let required, let additionalProperties, _):
            guard case .object(let object) = value else { throw violation(path) }
            for key in required where object[key] == nil { throw violation("\(path).\(key)") }
            if !additionalProperties {
                for key in object.keys where properties[key] == nil { throw violation("\(path).\(key)") }
            }
            for (key, child) in object {
                if let childSchema = properties[key] {
                    try validate(child, against: childSchema, path: "\(path).\(key)")
                }
            }
        case .array(let items, let minimumItems, let maximumItems, _):
            guard case .array(let array) = value else { throw violation(path) }
            if let minimumItems, array.count < minimumItems { throw violation(path) }
            if let maximumItems, array.count > maximumItems { throw violation(path) }
            for (index, child) in array.enumerated() {
                try validate(child, against: items, path: "\(path)[\(index)]")
            }
        case .string(let allowedValues, let format, let minimumLength, let maximumLength, _):
            guard case .string(let string) = value else { throw violation(path) }
            if let allowedValues, !allowedValues.contains(string) { throw violation(path) }
            if let minimumLength, string.count < minimumLength { throw violation(path) }
            if let maximumLength, string.count > maximumLength { throw violation(path) }
            if format == "date-time", ISO8601DateFormatter().date(from: string) == nil {
                throw violation(path)
            }
        case .number(let minimum, let maximum, _):
            guard let number = value.doubleValue, number.isFinite else { throw violation(path) }
            if let minimum, number < minimum { throw violation(path) }
            if let maximum, number > maximum { throw violation(path) }
        case .integer(let minimum, let maximum, _):
            guard let integer = value.intValue else { throw violation(path) }
            if let minimum, integer < minimum { throw violation(path) }
            if let maximum, integer > maximum { throw violation(path) }
        case .boolean:
            guard value.boolValue != nil else { throw violation(path) }
        case .null:
            guard case .null = value else { throw violation(path) }
        case .anyOf(let alternatives, _):
            guard alternatives.contains(where: { (try? validate(value, against: $0, path: path)) != nil }) else {
                throw violation(path)
            }
        }
    }

    private static func violation(_ path: String) -> ProviderError {
        .schemaViolation(path: path)
    }
}

import Foundation

@testable import TiantingIM

/// A small JSON Schema (2020-12 subset) validator: exactly the keywords frame.schema.json uses.
/// Used to run vectors/frames.json and to check every frame the SDK sends in tests.
final class SchemaValidator: @unchecked Sendable {
    private let root: JSONValue
    nonisolated(unsafe) private static var cached: SchemaValidator?

    init(root: JSONValue) {
        self.root = root
    }

    /// `protocol/schema/http-client.schema.json`.
    static func http() throws -> SchemaValidator {
        if let c = cachedHttp { return c }
        let v = SchemaValidator(root: try loadJSON("schema/http-client.schema.json"))
        cachedHttp = v
        return v
    }
    nonisolated(unsafe) private static var cachedHttp: SchemaValidator?

    static func shared() throws -> SchemaValidator {
        if let c = cached { return c }
        let v = SchemaValidator(root: try loadJSON("schema/frame.schema.json"))
        cached = v
        return v
    }

    func isValid(_ value: JSONValue) -> Bool {
        check(value, root)
    }

    /// Checks against a definition in the same file, e.g. `#/$defs/AuthResponse`.
    func isValid(_ value: JSONValue, ref: String) -> Bool {
        check(value, resolve(ref))
    }

    private static let handled: Set<String> = [
        "$schema", "$id", "$defs", "title", "description", "$comment", "default", "examples", "$ref", "type", "const", "enum", "properties",
        "required", "additionalProperties", "items", "minItems", "maxItems", "minLength", "maxLength", "pattern",
        "minimum", "maximum", "minProperties", "maxProperties", "oneOf", "anyOf", "allOf", "not", "if", "then", "else",
        "propertyNames",
    ]

    private func resolve(_ ref: String) -> JSONValue {
        var cur = root
        for part in ref.dropFirst(2).split(separator: "/") { cur = cur[String(part)] ?? .null }
        return cur
    }

    private func matchesType(_ v: JSONValue, _ t: String) -> Bool {
        switch (t, v) {
        case ("string", .string), ("boolean", .bool), ("null", .null), ("array", .array), ("object", .object),
            ("integer", .int), ("number", .int), ("number", .double):
            return true
        case ("integer", .double(let d)):
            return d == d.rounded()
        default:
            return false
        }
    }

    private func check(_ v: JSONValue, _ s: JSONValue) -> Bool {
        if case .bool(let b) = s { return b }
        guard case .object(let schema) = s else { return true }
        for key in schema.keys where !SchemaValidator.handled.contains(key) {
            fatalError("frame.schema.json uses unsupported keyword \(key)")
        }
        if let ref = schema["$ref"]?.stringValue, !check(v, resolve(ref)) { return false }
        if let t = schema["type"] {
            switch t {
            case .string(let name):
                if !matchesType(v, name) { return false }
            case .array(let names):
                if !names.contains(where: { matchesType(v, $0.stringValue ?? "") }) { return false }
            default:
                break
            }
        }
        if let c = schema["const"], !sameJSON(c, v) { return false }
        if let e = schema["enum"]?.arrayValue, !e.contains(where: { sameJSON($0, v) }) { return false }
        if case .string(let str) = v {
            let n = str.unicodeScalars.count
            if let m = schema["minLength"]?.intValue, n < m { return false }
            if let m = schema["maxLength"]?.intValue, n > m { return false }
            if let p = schema["pattern"]?.stringValue,
                str.range(of: p, options: .regularExpression) == nil
            {
                return false
            }
        }
        if let num = number(v) {
            if let m = schema["minimum"].flatMap(number), num < m { return false }
            if let m = schema["maximum"].flatMap(number), num > m { return false }
        }
        if case .array(let items) = v {
            if let m = schema["minItems"]?.intValue, items.count < m { return false }
            if let m = schema["maxItems"]?.intValue, items.count > m { return false }
            if let item = schema["items"], !items.allSatisfy({ check($0, item) }) { return false }
        }
        if case .object(let o) = v {
            if let m = schema["minProperties"]?.intValue, o.count < m { return false }
            if let m = schema["maxProperties"]?.intValue, o.count > m { return false }
            for r in schema["required"]?.arrayValue ?? [] where o[r.stringValue ?? ""] == nil { return false }
            if let names = schema["propertyNames"], !o.keys.allSatisfy({ check(.string($0), names) }) { return false }
            let props: [String: JSONValue]
            if case .object(let p)? = schema["properties"] { props = p } else { props = [:] }
            for (k, value) in o {
                if let sub = props[k] {
                    if !check(value, sub) { return false }
                } else if let extra = schema["additionalProperties"], !check(value, extra) {
                    return false
                }
            }
        }
        if let all = schema["allOf"]?.arrayValue, !all.allSatisfy({ check(v, $0) }) { return false }
        if let any = schema["anyOf"]?.arrayValue, !any.contains(where: { check(v, $0) }) { return false }
        if let one = schema["oneOf"]?.arrayValue, one.filter({ check(v, $0) }).count != 1 { return false }
        if let not = schema["not"], check(v, not) { return false }
        if let cond = schema["if"] {
            if check(v, cond) {
                if let then = schema["then"], !check(v, then) { return false }
            } else if let els = schema["else"], !check(v, els) {
                return false
            }
        }
        return true
    }

    private func number(_ v: JSONValue) -> Double? {
        switch v {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }

    private func sameJSON(_ a: JSONValue, _ b: JSONValue) -> Bool {
        if let x = number(a), let y = number(b) { return x == y }
        return a == b
    }
}

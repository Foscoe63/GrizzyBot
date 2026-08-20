import Foundation

/// Small CEL subset used by action policy: literals, dotted fields, ==/!=, &&/||/!, contains(), matches().
public enum PolicyCEL {
    public enum Value: Sendable, Equatable {
        case bool(Bool)
        case string(String)
        case number(Double)
        case object([String: Value])
        case null

        var boolValue: Bool? {
            if case .bool(let value) = self { return value }
            return nil
        }

        func stringify() -> String {
            switch self {
            case .bool(let value): return value ? "true" : "false"
            case .string(let value): return value
            case .number(let value):
                if value.rounded() == value { return String(Int(value)) }
                return String(value)
            case .object: return "[object]"
            case .null: return ""
            }
        }
    }

    public enum EvalError: Error, Equatable {
        case empty
        case unexpected(String)
        case unknownField(String)
        case invalidPattern(String)
        case typeMismatch
    }

    public static func evaluate(_ source: String, values: [String: Value]) throws -> Bool {
        var parser = Parser(source: source, values: values)
        let value = try parser.parseExpression()
        try parser.expectEnd()
        guard let bool = value.boolValue else { throw EvalError.typeMismatch }
        return bool
    }

    private struct Parser {
        let chars: [Character]
        var index = 0
        let values: [String: Value]

        init(source: String, values: [String: Value]) {
            self.chars = Array(source)
            self.values = values
        }

        mutating func parseExpression() throws -> Value {
            skip()
            if atEnd { throw EvalError.empty }
            return try parseOr()
        }

        mutating func expectEnd() throws {
            skip()
            if !atEnd { throw EvalError.unexpected(String(remaining)) }
        }

        mutating func parseOr() throws -> Value {
            var left = try parseAnd()
            while match("||") {
                let right = try parseAnd()
                left = .bool(truthy(left) || truthy(right))
            }
            return left
        }

        mutating func parseAnd() throws -> Value {
            var left = try parseEq()
            while match("&&") {
                let right = try parseEq()
                left = .bool(truthy(left) && truthy(right))
            }
            return left
        }

        mutating func parseEq() throws -> Value {
            let left = try parseUnary()
            skip()
            if match("==") {
                let right = try parseUnary()
                return .bool(equal(left, right))
            }
            if match("!=") {
                let right = try parseUnary()
                return .bool(!equal(left, right))
            }
            return left
        }

        mutating func parseUnary() throws -> Value {
            skip()
            if match("!") {
                return .bool(!truthy(try parseUnary()))
            }
            return try parsePrimary()
        }

        mutating func parsePrimary() throws -> Value {
            skip()
            if match("(") {
                let inner = try parseOr()
                skip()
                guard match(")") else { throw EvalError.unexpected("missing )") }
                return inner
            }
            if peek == "\"" {
                return .string(try parseString())
            }
            if let number = tryParseNumber() {
                return .number(number)
            }
            let ident = try parseIdent()
            if ident == "true" { return .bool(true) }
            if ident == "false" { return .bool(false) }
            skip()
            if match("(") {
                let args = try parseArgs()
                return try call(ident, args)
            }
            return try lookup(ident)
        }

        mutating func parseArgs() throws -> [Value] {
            skip()
            if match(")") { return [] }
            var args: [Value] = [try parseOr()]
            while true {
                skip()
                if match(")") { break }
                guard match(",") else { throw EvalError.unexpected("expected , or )") }
                args.append(try parseOr())
            }
            return args
        }

        mutating func lookup(_ first: String) throws -> Value {
            var path = [first]
            while match(".") {
                path.append(try parseIdent())
            }
            var current: Value = .object(values)
            for key in path {
                guard case .object(let object) = current, let next = object[key] else {
                    throw EvalError.unknownField(path.joined(separator: "."))
                }
                current = next
            }
            return current
        }

        func call(_ name: String, _ args: [Value]) throws -> Value {
            switch name {
            case "contains":
                guard args.count == 2 else { throw EvalError.unexpected("contains needs 2 arguments") }
                let hay = args[0].stringify().lowercased()
                let needle = args[1].stringify().lowercased()
                return .bool(hay.contains(needle))
            case "matches":
                guard args.count == 2 else { throw EvalError.unexpected("matches needs 2 arguments") }
                let pattern = args[1].stringify()
                do {
                    let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
                    let text = args[0].stringify()
                    let range = NSRange(text.startIndex..., in: text)
                    return .bool(regex.firstMatch(in: text, range: range) != nil)
                } catch {
                    throw EvalError.invalidPattern(pattern)
                }
            default:
                throw EvalError.unexpected("unknown function \(name)")
            }
        }

        mutating func parseIdent() throws -> String {
            skip()
            guard let first = peek, first.isLetter || first == "_" else {
                throw EvalError.unexpected("expected identifier")
            }
            var out = ""
            while let ch = peek, ch.isLetter || ch.isNumber || ch == "_" {
                out.append(ch)
                advance()
            }
            return out
        }

        mutating func parseString() throws -> String {
            guard match("\"") else { throw EvalError.unexpected("expected string") }
            var out = ""
            while !atEnd {
                let ch = advance()
                if ch == "\"" { return out }
                if ch == "\\" {
                    guard !atEnd else { throw EvalError.unexpected("unterminated string") }
                    let escaped = advance()
                    switch escaped {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    default: out.append(escaped)
                    }
                    continue
                }
                out.append(ch)
            }
            throw EvalError.unexpected("unterminated string")
        }

        mutating func tryParseNumber() -> Double? {
            skip()
            let start = index
            if peek == "-" { advance() }
            guard let first = peek, first.isNumber else {
                index = start
                return nil
            }
            while let ch = peek, ch.isNumber { advance() }
            if peek == "." {
                advance()
                while let ch = peek, ch.isNumber { advance() }
            }
            return Double(String(chars[start..<index]))
        }

        mutating func match(_ token: String) -> Bool {
            skip()
            let t = Array(token)
            guard index + t.count <= chars.count else { return false }
            if Array(chars[index..<(index + t.count)]) == t {
                let after = index + t.count
                if token.allSatisfy({ $0.isLetter }), after < chars.count,
                   chars[after].isLetter || chars[after].isNumber || chars[after] == "_" {
                    return false
                }
                index = after
                return true
            }
            return false
        }

        mutating func skip() {
            while let ch = peek, ch.isWhitespace { advance() }
        }

        var peek: Character? { atEnd ? nil : chars[index] }
        var atEnd: Bool { index >= chars.count }
        var remaining: ArraySlice<Character> { chars[index...] }

        @discardableResult
        mutating func advance() -> Character {
            let ch = chars[index]
            index += 1
            return ch
        }

        func truthy(_ value: Value) -> Bool {
            switch value {
            case .bool(let v): return v
            case .string(let v): return !v.isEmpty
            case .number(let v): return v != 0
            case .object(let v): return !v.isEmpty
            case .null: return false
            }
        }

        func equal(_ lhs: Value, _ rhs: Value) -> Bool {
            switch (lhs, rhs) {
            case (.bool(let a), .bool(let b)): return a == b
            case (.string(let a), .string(let b)): return a == b
            case (.number(let a), .number(let b)): return a == b
            case (.null, .null): return true
            case (.string(let a), .bool(let b)): return a.lowercased() == (b ? "true" : "false")
            case (.bool(let a), .string(let b)): return b.lowercased() == (a ? "true" : "false")
            default: return lhs.stringify() == rhs.stringify()
            }
        }
    }
}

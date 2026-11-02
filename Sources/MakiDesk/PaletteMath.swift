import Foundation

/// A calculation understood by the palette's search field (U1).
///
/// The value is kept for tests and for a future "insert the number only"
/// action; `text` is what the palette shows and copies, unit included.
struct PaletteCalculation: Equatable, Sendable {
    let value: Double
    /// Canonical unit symbol, e.g. "cm", "°F", "GB"; nil for a plain number.
    let unit: String?
    let text: String
}

/// The arithmetic behind `⌥Space` (U1): pure, locale-aware for the separators,
/// and deliberately small. It understands numbers, `+ - * / % ^`, parentheses,
/// `sqrt/abs/round/floor/ceil`, percentages and a closed table of units.
///
/// No currency: rates need the network, and this app does not use one.
enum PaletteMath {
    /// Long inputs are rejected before the parser allocates anything: the field
    /// is a search box, not a scratchpad.
    static let maximumLength = 200
    static let maximumTokens = 128
    static let maximumDepth = 16
    /// `2 ^ 1000000` must not hang the typing path.
    static let maximumExponent = 12.0

    /// Parses and formats in one step. Nil means "not an expression": the
    /// palette then shows no result row and the windows keep the stage.
    static func evaluate(_ raw: String, locale: Locale = .current) -> PaletteCalculation? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false, trimmed.count <= maximumLength else { return nil }
        do {
            var lexer = Lexer(text: trimmed, locale: locale)
            let tokens = try lexer.scan()
            guard tokens.count <= maximumTokens else { return nil }
            var parser = Parser(tokens: tokens)
            let expression = try parser.parse()
            let quantity = try Evaluator().evaluate(expression)
            guard quantity.value.isFinite else { return nil }
            let text = format(quantity.value, unit: quantity.unit, locale: locale)
            return PaletteCalculation(value: quantity.value, unit: quantity.unit?.symbol, text: text)
        } catch {
            return nil
        }
    }

    // MARK: - Formatting

    /// Up to ten fraction digits, grouping according to the locale, and a
    /// space before the unit. Values outside the readable range use a compact
    /// representation instead of a wall of zeros.
    static func format(_ value: Double, unit: CalculationUnit?, locale: Locale) -> String {
        let clean = value == 0 ? 0 : value
        let magnitude = abs(clean)
        if magnitude != 0, magnitude >= 1e12 || magnitude < 1e-9 {
            let scientific = String(format: "%.6g", clean)
            let decimal = locale.decimalSeparator ?? "."
            let localized = scientific.replacingOccurrences(of: ".", with: decimal)
            guard let unit else { return localized }
            return "\(localized) \(unit.symbol)"
        }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.maximumFractionDigits = 10
        formatter.minimumFractionDigits = 0
        formatter.maximumSignificantDigits = 10
        let number = formatter.string(from: NSNumber(value: clean)) ?? String(clean)
        guard let unit else { return number }
        return "\(number) \(unit.symbol)"
    }

    // MARK: - Units

    /// One unit of measure. Conversion to the base unit is
    /// `value * factor + offset`, which covers the temperature scales without a
    /// second table or closures.
    struct CalculationUnit: Equatable, Sendable {
        enum Dimension: Equatable, Sendable {
            case length, mass, temperature, data, time
        }

        let symbol: String
        let dimension: Dimension
        let factor: Double
        let offset: Double
    }

    /// Canonical units, keyed by lower-case alias with the degree sign removed.
    static let units: [String: CalculationUnit] = {
        var table: [String: CalculationUnit] = [:]

        func add(_ symbol: String, _ dimension: CalculationUnit.Dimension,
                 _ factor: Double, offset: Double = 0, _ aliases: [String]) {
            let unit = CalculationUnit(symbol: symbol, dimension: dimension,
                                       factor: factor, offset: offset)
            for alias in aliases { table[alias] = unit }
            table[symbol.lowercased().replacingOccurrences(of: "°", with: "")] = unit
        }

        // Length, base metre.
        add("mm", .length, 0.001, ["millimeter", "millimeters", "millimetre", "millimetres"])
        add("cm", .length, 0.01, ["centimeter", "centimeters", "centimetre", "centimetres"])
        add("m", .length, 1, ["meter", "meters", "metre", "metres"])
        add("km", .length, 1000, ["kilometer", "kilometers", "kilometre", "kilometres"])
        add("in", .length, 0.0254, ["inch", "inches"])
        add("ft", .length, 0.3048, ["foot", "feet"])
        add("yd", .length, 0.9144, ["yard", "yards"])
        add("mi", .length, 1609.344, ["mile", "miles"])

        // Mass, base gram.
        add("mg", .mass, 0.001, ["milligram", "milligrams"])
        add("g", .mass, 1, ["gram", "grams"])
        add("kg", .mass, 1000, ["kilogram", "kilograms", "kilo", "kilos"])
        add("oz", .mass, 28.349523125, ["ounce", "ounces"])
        add("lb", .mass, 453.59237, ["lbs", "pound", "pounds"])

        // Temperature, base kelvin: °C = K - 273.15, °F = K * 9/5 - 459.67.
        add("°C", .temperature, 1, offset: 273.15, ["c", "celsius", "centigrade"])
        add("°F", .temperature, 5.0 / 9.0, offset: 459.67 * 5.0 / 9.0,
            ["f", "fahrenheit"])
        add("K", .temperature, 1, ["kelvin"])

        // Data, decimal and binary.
        add("B", .data, 1, ["byte", "bytes"])
        add("KB", .data, 1_000, ["kilobyte", "kilobytes"])
        add("MB", .data, 1_000_000, ["megabyte", "megabytes"])
        add("GB", .data, 1_000_000_000, ["gigabyte", "gigabytes"])
        add("TB", .data, 1_000_000_000_000, ["terabyte", "terabytes"])
        add("KiB", .data, 1024, ["kibibyte", "kibibytes"])
        add("MiB", .data, 1024 * 1024, ["mebibyte", "mebibytes"])
        add("GiB", .data, 1024 * 1024 * 1024, ["gibibyte", "gibibytes"])
        add("TiB", .data, 1024 * 1024 * 1024 * 1024, ["tebibyte", "tebibytes"])

        // Time, base second.
        add("s", .time, 1, ["sec", "secs", "second", "seconds"])
        add("min", .time, 60, ["mins", "minute", "minutes"])
        add("h", .time, 3600, ["hr", "hrs", "hour", "hours"])
        add("d", .time, 86_400, ["day", "days"])

        return table
    }()

    static func unit(named raw: String) -> CalculationUnit? {
        let key = raw.lowercased().replacingOccurrences(of: "°", with: "")
        return units[key]
    }

    // MARK: - Expressions

    fileprivate indirect enum Expression: Equatable {
        case literal(Double)
        case withUnit(Expression, CalculationUnit)
        case percent(Expression)
        case negate(Expression)
        case binary(Op, Expression, Expression)
        case call(String, Expression)
        case percentOf(Expression, Expression)
        case convert(Expression, CalculationUnit)

        enum Op: Equatable {
            case add, subtract, multiply, divide, power, modulo
        }
    }

    fileprivate struct Quantity {
        var value: Double
        var unit: CalculationUnit?
        var isPercent = false
    }

    fileprivate enum ParseError: Error {
        case empty, unexpected, unbalanced, tooDeep, tooLong
    }

    // MARK: - Lexer

    fileprivate enum Token: Equatable {
        case number(Double)
        case identifier(String)
        case symbol(Character)

        var identifierValue: String? {
            if case let .identifier(name) = self { return name }
            return nil
        }
    }

    fileprivate struct Lexer {
        let text: String
        let locale: Locale
        private var index: String.Index
        private var tokens: [Token] = []

        init(text: String, locale: Locale) {
            self.text = text
            self.locale = locale
            self.index = text.startIndex
        }

        mutating func scan() throws -> [Token] {
            let decimal = Character(locale.decimalSeparator ?? ".")
            let grouping = Character(locale.groupingSeparator ?? (decimal == "." ? "," : "."))
            while index < text.endIndex {
                let character = text[index]
                if character.isWhitespace {
                    index = text.index(after: index)
                    continue
                }
                if character.isASCII && character.isNumber {
                    try scanNumber(decimal: decimal, grouping: grouping)
                    continue
                }
                if isIdentifierStart(character) {
                    scanIdentifier()
                    continue
                }
                if "+-*/^()%".contains(character) {
                    tokens.append(.symbol(character))
                    index = text.index(after: index)
                    continue
                }
                throw ParseError.unexpected
            }
            return tokens
        }

        private func isIdentifierStart(_ character: Character) -> Bool {
            character.isLetter || character == "°" || character == "µ"
        }

        private func isIdentifierBody(_ character: Character) -> Bool {
            character.isLetter || character.isNumber || character == "°" || character == "µ"
        }

        private mutating func scanIdentifier() {
            var value = ""
            while index < text.endIndex, isIdentifierBody(text[index]) {
                value.append(text[index])
                index = text.index(after: index)
            }
            tokens.append(.identifier(value.lowercased()))
        }

        private mutating func scanNumber(decimal: Character, grouping: Character) throws {
            var raw = ""
            while index < text.endIndex {
                let character = text[index]
                if character.isASCII && character.isNumber {
                    raw.append(character)
                    index = text.index(after: index)
                } else if character == decimal || character == grouping {
                    raw.append(character)
                    index = text.index(after: index)
                } else {
                    break
                }
            }
            guard let value = Self.number(raw, decimal: decimal, grouping: grouping) else {
                throw ParseError.unexpected
            }
            tokens.append(.number(value))
        }

        /// Locale-aware number. The decimal separator becomes a dot; a grouping
        /// separator is skipped only between proper groups of three. When the
        /// locale's grouping character is the only separator and has one or two
        /// digits after it, it is read as the decimal instead: an Italian user
        /// typing `1.5` means one and a half, not fifteen hundred.
        static func number(_ raw: String, decimal: Character, grouping: Character) -> Double? {
            var characters = Array(raw)
            guard characters.isEmpty == false else { return nil }
            if grouping != decimal {
                let decimals = characters.filter { $0 == decimal }.count
                let groups = characters.indices.filter { characters[$0] == grouping }
                if decimals == 0, groups.count == 1, let at = groups.first {
                    let following = characters.count - at - 1
                    if following == 1 || following == 2 { characters[at] = decimal }
                }
            }
            var normalized = ""
            for (offset, character) in characters.enumerated() {
                if character == decimal {
                    guard normalized.contains(".") == false, normalized.isEmpty == false else {
                        return nil
                    }
                    normalized.append(".")
                } else if character == grouping {
                    guard normalized.isEmpty == false,
                          offset + 3 < characters.count,
                          characters[offset + 1].isNumber,
                          characters[offset + 2].isNumber,
                          characters[offset + 3].isNumber,
                          offset + 4 == characters.count
                            || !characters[offset + 4].isNumber else {
                        return nil
                    }
                } else if character.isNumber {
                    normalized.append(character)
                } else {
                    return nil
                }
            }
            guard normalized.isEmpty == false else { return nil }
            return Double(normalized)
        }
    }

    // MARK: - Parser

    fileprivate struct Parser {
        let tokens: [Token]
        private var index = 0
        private var depth = 0

        init(tokens: [Token]) {
            self.tokens = tokens
        }

        mutating func parse() throws -> Expression {
            guard tokens.isEmpty == false else { throw ParseError.empty }
            var expression = try parseAdditive()
            // `15% of 80` is handled at multiplicative level; here only the
            // conversion suffix remains: `12 cm in in`.
            if match(identifier: "in") || match(identifier: "to") || match(identifier: "as") {
                guard let name = peek()?.identifierValue, let target = PaletteMath.unit(named: name) else {
                    throw ParseError.unexpected
                }
                advance()
                expression = .convert(expression, target)
            }
            guard index == tokens.count else { throw ParseError.unexpected }
            return expression
        }

        private mutating func parseAdditive() throws -> Expression {
            var left = try parseMultiplicative()
            while true {
                if match(symbol: "+") {
                    left = .binary(.add, left, try parseMultiplicative())
                } else if match(symbol: "-") {
                    left = .binary(.subtract, left, try parseMultiplicative())
                } else {
                    return left
                }
            }
        }

        private mutating func parseMultiplicative() throws -> Expression {
            var left = try parseUnary()
            while true {
                if match(symbol: "*") {
                    left = .binary(.multiply, left, try parseUnary())
                } else if match(symbol: "/") {
                    left = .binary(.divide, left, try parseUnary())
                } else if match(identifier: "mod") {
                    left = .binary(.modulo, left, try parseUnary())
                } else if match(identifier: "of") {
                    left = .percentOf(left, try parsePower())
                } else {
                    return left
                }
            }
        }

        private mutating func parseUnary() throws -> Expression {
            if match(symbol: "+") { return try parseUnary() }
            if match(symbol: "-") { return .negate(try parseUnary()) }
            return try parsePower()
        }

        /// Right associative: `2 ^ 3 ^ 2` is `2 ^ (3 ^ 2)`.
        private mutating func parsePower() throws -> Expression {
            var left = try parsePostfix()
            if match(symbol: "^") {
                left = .binary(.power, left, try parseUnary())
            }
            return left
        }

        private mutating func parsePostfix() throws -> Expression {
            var value = try parsePrimary()
            if match(symbol: "%") {
                value = .percent(value)
            }
            // A unit follows a value without an operator: `12 cm`, `30 °C`.
            // `in` is both the inch and the conversion keyword; the unit wins,
            // and a conversion then uses `to` (or a second `in`: `12 in in cm`).
            if let name = peek()?.identifierValue,
               let unit = PaletteMath.unit(named: name) {
                advance()
                value = .withUnit(value, unit)
            }
            return value
        }

        private mutating func parsePrimary() throws -> Expression {
            guard let token = peek() else { throw ParseError.unexpected }
            switch token {
            case let .number(value):
                advance()
                return .literal(value)
            case .symbol("("):
                depth += 1
                guard depth <= PaletteMath.maximumDepth else { throw ParseError.tooDeep }
                advance()
                let inner = try parseAdditive()
                guard match(symbol: ")") else { throw ParseError.unbalanced }
                depth -= 1
                return inner
            case let .identifier(name):
                advance()
                if name == "pi" { return .literal(Double.pi) }
                if name == "e" { return .literal(exp(1)) }
                if match(symbol: "(") {
                    depth += 1
                    guard depth <= PaletteMath.maximumDepth else { throw ParseError.tooDeep }
                    let argument = try parseAdditive()
                    guard match(symbol: ")") else { throw ParseError.unbalanced }
                    depth -= 1
                    guard Self.supportedFunctions.contains(name) else { throw ParseError.unexpected }
                    return .call(name, argument)
                }
                throw ParseError.unexpected
            default:
                throw ParseError.unexpected
            }
        }

        private static let supportedFunctions: Set<String> = [
            "sqrt", "abs", "round", "floor", "ceil"
        ]

        private func peek() -> Token? {
            index < tokens.count ? tokens[index] : nil
        }

        private mutating func advance() {
            index += 1
        }

        private mutating func match(symbol: Character) -> Bool {
            guard case let .symbol(value)? = peek(), value == symbol else { return false }
            advance()
            return true
        }

        private mutating func match(identifier: String) -> Bool {
            guard case let .identifier(value)? = peek(), value == identifier else { return false }
            advance()
            return true
        }
    }

    // MARK: - Evaluation

    fileprivate struct Evaluator {
        func evaluate(_ expression: Expression) throws -> Quantity {
            switch expression {
            case let .literal(value):
                return Quantity(value: value)
            case let .withUnit(inner, unit):
                let base = try evaluate(inner)
                guard base.unit == nil, base.isPercent == false else { throw ParseError.unexpected }
                return Quantity(value: base.value, unit: unit)
            case let .percent(inner):
                let base = try evaluate(inner)
                guard base.unit == nil, base.isPercent == false else { throw ParseError.unexpected }
                return Quantity(value: base.value / 100, isPercent: true)
            case let .negate(inner):
                var base = try evaluate(inner)
                base.value = -base.value
                base.isPercent = false
                return base
            case let .binary(op, left, right):
                return try binary(op, evaluate(left), evaluate(right))
            case let .call(name, argument):
                return try call(name, evaluate(argument))
            case let .percentOf(percent, base):
                let rate = try evaluate(percent)
                let quantity = try evaluate(base)
                guard rate.isPercent, rate.unit == nil else { throw ParseError.unexpected }
                return Quantity(value: quantity.value * rate.value, unit: quantity.unit)
            case let .convert(inner, target):
                let base = try evaluate(inner)
                guard let source = base.unit, source.dimension == target.dimension else {
                    throw ParseError.unexpected
                }
                let converted = (base.value * source.factor + source.offset - target.offset) / target.factor
                return Quantity(value: converted, unit: target)
            }
        }

        private func binary(_ op: Expression.Op, _ left: Quantity,
                            _ right: Quantity) throws -> Quantity {
            switch op {
            case .add, .subtract:
                if right.isPercent {
                    // `80 + 15%` is 80 + 15% of 80, the convention every
                    // calculator uses.
                    let delta = left.value * right.value
                    return Quantity(value: op == .add ? left.value + delta : left.value - delta,
                                    unit: left.unit)
                }
                let comparable = try matching(right, to: left.unit)
                let value = op == .add ? left.value + comparable : left.value - comparable
                return Quantity(value: value, unit: left.unit)
            case .multiply:
                guard left.unit == nil || right.unit == nil else { throw ParseError.unexpected }
                return Quantity(value: left.value * right.value,
                                unit: left.unit ?? right.unit)
            case .divide:
                guard right.value != 0 else { throw ParseError.unexpected }
                if left.unit != nil, right.unit != nil {
                    guard left.unit == right.unit else { throw ParseError.unexpected }
                    return Quantity(value: left.value / right.value)
                }
                guard right.unit == nil else { throw ParseError.unexpected }
                return Quantity(value: left.value / right.value, unit: left.unit)
            case .power:
                guard left.unit == nil, right.unit == nil, right.isPercent == false else {
                    throw ParseError.unexpected
                }
                guard abs(right.value) <= PaletteMath.maximumExponent else {
                    throw ParseError.unexpected
                }
                return Quantity(value: pow(left.value, right.value))
            case .modulo:
                guard left.unit == nil, right.unit == nil, right.value != 0 else {
                    throw ParseError.unexpected
                }
                return Quantity(value: left.value.truncatingRemainder(dividingBy: right.value))
            }
        }

        /// A bare quantity is read in the other side's unit; a unit of the same
        /// dimension is converted; anything else is a mistake.
        private func matching(_ quantity: Quantity, to unit: CalculationUnit?) throws -> Double {
            switch (quantity.unit, unit) {
            case (nil, nil):
                return quantity.value
            case let (source?, target?):
                guard source.dimension == target.dimension else { throw ParseError.unexpected }
                let base = quantity.value * source.factor + source.offset
                return (base - target.offset) / target.factor
            case (_?, nil), (nil, _?):
                throw ParseError.unexpected
            }
        }

        private func call(_ name: String, _ quantity: Quantity) throws -> Quantity {
            guard quantity.unit == nil, quantity.isPercent == false else {
                throw ParseError.unexpected
            }
            let value: Double
            switch name {
            case "sqrt":
                guard quantity.value >= 0 else { throw ParseError.unexpected }
                value = sqrt(quantity.value)
            case "abs": value = abs(quantity.value)
            case "round": value = quantity.value.rounded()
            case "floor": value = quantity.value.rounded(.down)
            case "ceil": value = quantity.value.rounded(.up)
            default: throw ParseError.unexpected
            }
            return Quantity(value: value)
        }
    }
}

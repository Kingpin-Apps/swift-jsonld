import Foundation

extension JSONLD {
    /// N-Quads serializer + parser for an RDF dataset.
    ///
    /// See [RDF 1.1 N-Quads](https://www.w3.org/TR/n-quads/) for the
    /// canonical grammar. The emitter produces line-per-quad output
    /// with sorted-quad ordering for stable diffs; the parser is
    /// lenient enough to read the W3C test-suite fixtures (which are
    /// canonical N-Quads — no quoted graphs, no comments mid-line).
    public enum NQuads {
        /// Serialize a dataset to an N-Quads string.
        public static func serialize(_ dataset: Dataset) -> String {
            var lines: [String] = []
            for quad in dataset.allQuads {
                lines.append(serialize(quad: quad))
            }
            lines.sort()
            return lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        }

        /// Serialize a single quad as one N-Quads line, without trailing newline.
        public static func serialize(quad: Quad) -> String {
            var s = "\(serialize(term: quad.subject)) \(serialize(term: quad.predicate)) \(serialize(term: quad.object))"
            if let g = quad.graph {
                s += " \(serialize(term: g))"
            }
            s += " ."
            return s
        }

        /// Serialize a single term in N-Quads syntax (`<iri>`,
        /// `_:bnode`, or `"literal"^^<datatype>` / `"literal"@lang`).
        public static func serialize(term: Term) -> String {
            switch term {
            case .iri(let iri):
                return "<\(iri)>"
            case .blankNode(let id):
                return id.hasPrefix("_:") ? id : "_:\(id)"
            case .literal(let lit):
                var s = "\"\(escape(lit.value))\""
                if let lang = lit.language {
                    s += "@\(lang)"
                } else if lit.datatype != Literal.xsdString {
                    s += "^^<\(lit.datatype)>"
                }
                return s
            }
        }

        /// Errors raised by ``parse(_:)`` / ``parseDataset(_:)``.
        public enum ParseError: Swift.Error, CustomStringConvertible {
            /// A character was found that isn't valid in this position.
            case unexpectedCharacter(line: Int, column: Int, char: Character?)
            /// A quoted literal was not closed before EOF or a newline.
            case unterminatedString(line: Int)
            /// A backslash escape (`\\u…`, `\\t`, etc.) was malformed.
            case invalidEscape(line: Int, sequence: String)
            /// An IRI (`<…>`) was not closed before EOF.
            case invalidIRI(line: Int)
            /// A specific token was expected but not found.
            case expected(line: Int, what: String)

            public var description: String {
                switch self {
                case .unexpectedCharacter(let l, let c, let ch):
                    return "n-quads: unexpected character \(ch.map { "'\($0)'" } ?? "EOF") at line \(l):\(c)"
                case .unterminatedString(let l):
                    return "n-quads: unterminated string literal at line \(l)"
                case .invalidEscape(let l, let s):
                    return "n-quads: invalid escape sequence \(s) at line \(l)"
                case .invalidIRI(let l):
                    return "n-quads: invalid IRI at line \(l)"
                case .expected(let l, let what):
                    return "n-quads: expected \(what) at line \(l)"
                }
            }
        }

        /// Parse an N-Quads document into a flat array of quads.
        ///
        /// Whitespace, blank lines, and `# …` comments are skipped.
        /// Each non-empty line must end with `.`. The graph slot
        /// (optional fourth term) goes into `Quad.graph`; quads with
        /// no graph go to the default graph by carrying a `nil` graph.
        public static func parse(_ input: String) throws -> [Quad] {
            var p = Parser(input: input)
            return try p.parseDocument()
        }

        /// Parse an N-Quads document and group the quads into a `Dataset`.
        public static func parseDataset(_ input: String) throws -> Dataset {
            let quads = try parse(input)
            var ds = Dataset()
            for q in quads {
                if let g = q.graph {
                    let key: String
                    switch g {
                    case .iri(let s): key = s
                    case .blankNode(let s): key = s
                    case .literal: key = "_:literal-graph"
                    }
                    ds.namedGraphs[key, default: []].append(q)
                } else {
                    ds.defaultGraph.append(q)
                }
            }
            return ds
        }

        private static func escape(_ s: String) -> String {
            var out = ""
            out.reserveCapacity(s.count)
            for ch in s {
                switch ch {
                case "\\": out += "\\\\"
                case "\"": out += "\\\""
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                default: out.append(ch)
                }
            }
            return out
        }
    }
}

private struct Parser {
    let scalars: [Unicode.Scalar]
    var index: Int = 0
    var line: Int = 1
    var column: Int = 1

    init(input: String) {
        self.scalars = Array(input.unicodeScalars)
    }

    var isAtEnd: Bool { index >= scalars.count }

    var peek: Unicode.Scalar? { isAtEnd ? nil : scalars[index] }

    mutating func advance() -> Unicode.Scalar? {
        guard !isAtEnd else { return nil }
        let s = scalars[index]
        index += 1
        if s == "\n" { line += 1; column = 1 } else { column += 1 }
        return s
    }

    mutating func match(_ s: Unicode.Scalar) -> Bool {
        if peek == s { _ = advance(); return true }
        return false
    }

    mutating func skipInlineWhitespace() {
        while let c = peek, c == " " || c == "\t" { _ = advance() }
    }

    mutating func skipLineWhitespace() {
        while let c = peek {
            switch c {
            case " ", "\t", "\n", "\r": _ = advance()
            case "#":
                while let cc = peek, cc != "\n" { _ = advance() }
            default: return
            }
        }
    }

    mutating func parseDocument() throws -> [JSONLD.Quad] {
        var out: [JSONLD.Quad] = []
        while !isAtEnd {
            skipLineWhitespace()
            if isAtEnd { break }
            let quad = try parseQuad()
            out.append(quad)
        }
        return out
    }

    mutating func parseQuad() throws -> JSONLD.Quad {
        skipInlineWhitespace()
        let subject = try parseTerm(isPredicate: false)
        skipInlineWhitespace()
        let predicate = try parseTerm(isPredicate: true)
        skipInlineWhitespace()
        let object = try parseTerm(isPredicate: false)
        skipInlineWhitespace()

        var graph: JSONLD.Term? = nil
        if let c = peek, c != "." {
            graph = try parseTerm(isPredicate: false)
            skipInlineWhitespace()
        }
        guard match(".") else {
            throw JSONLD.NQuads.ParseError.expected(line: line, what: "'.'")
        }
        // Eat trailing whitespace / newline.
        while let c = peek, c == " " || c == "\t" { _ = advance() }
        if let c = peek, c == "\n" || c == "\r" { _ = advance() }
        return JSONLD.Quad(subject: subject, predicate: predicate, object: object, graph: graph)
    }

    mutating func parseTerm(isPredicate: Bool) throws -> JSONLD.Term {
        guard let c = peek else {
            throw JSONLD.NQuads.ParseError.unexpectedCharacter(line: line, column: column, char: Optional<Character>.none)
        }
        switch c {
        case "<": return .iri(try parseIRI())
        case "_":
            return .blankNode(try parseBlankNode())
        case "\"":
            return .literal(try parseLiteral())
        default:
            throw JSONLD.NQuads.ParseError.unexpectedCharacter(line: line, column: column, char: Character(c))
        }
    }

    mutating func parseIRI() throws -> String {
        _ = advance() // consume '<'
        var out = ""
        while let c = peek {
            if c == ">" { _ = advance(); return out }
            if c == "\\" {
                _ = advance()
                guard let esc = try parseEscape() else {
                    throw JSONLD.NQuads.ParseError.invalidIRI(line: line)
                }
                out.unicodeScalars.append(esc)
            } else {
                out.unicodeScalars.append(c)
                _ = advance()
            }
        }
        throw JSONLD.NQuads.ParseError.invalidIRI(line: line)
    }

    mutating func parseBlankNode() throws -> String {
        _ = advance() // _
        guard match(":") else {
            throw JSONLD.NQuads.ParseError.expected(line: line, what: "':' after '_'")
        }
        var out = "_:"
        while let c = peek {
            if c.isASCII, c.properties.isAlphabetic ||
                ("0"..."9").contains(c) ||
                c == "_" || c == "-" || c == "." {
                out.unicodeScalars.append(c)
                _ = advance()
            } else {
                break
            }
        }
        // Trim trailing '.' if it's actually the quad terminator —
        // peek ahead: if the next non-`.` is whitespace or '<' etc,
        // the trailing dot is the terminator.
        if out.hasSuffix(".") {
            out.removeLast()
            index -= 1
            column -= 1
        }
        return out
    }

    mutating func parseLiteral() throws -> JSONLD.Literal {
        _ = advance() // '"'
        var value = ""
        while let c = peek {
            if c == "\"" {
                _ = advance()
                break
            }
            if c == "\\" {
                _ = advance()
                guard let esc = try parseEscape() else {
                    throw JSONLD.NQuads.ParseError.invalidEscape(line: line, sequence: "\\")
                }
                value.unicodeScalars.append(esc)
            } else if c == "\n" {
                throw JSONLD.NQuads.ParseError.unterminatedString(line: line)
            } else {
                value.unicodeScalars.append(c)
                _ = advance()
            }
        }

        var datatype = JSONLD.Literal.xsdString
        var language: String? = nil
        if peek == "@" {
            _ = advance()
            var lang = ""
            while let c = peek, c.isASCII,
                  c.properties.isAlphabetic || ("0"..."9").contains(c) || c == "-" {
                lang.unicodeScalars.append(c)
                _ = advance()
            }
            language = lang
            datatype = JSONLD.Literal.rdfLangString
        } else if peek == "^" {
            _ = advance()
            guard match("^") else {
                throw JSONLD.NQuads.ParseError.expected(line: line, what: "'^^'")
            }
            skipInlineWhitespace()
            guard peek == "<" else {
                throw JSONLD.NQuads.ParseError.expected(line: line, what: "'<' for datatype IRI")
            }
            datatype = try parseIRI()
        }
        return JSONLD.Literal(value: value, datatype: datatype, language: language)
    }

    mutating func parseEscape() throws -> Unicode.Scalar? {
        guard let c = advance() else { return nil }
        switch c {
        case "t": return Unicode.Scalar(0x09)
        case "b": return Unicode.Scalar(0x08)
        case "n": return Unicode.Scalar(0x0A)
        case "r": return Unicode.Scalar(0x0D)
        case "f": return Unicode.Scalar(0x0C)
        case "\"": return Unicode.Scalar(0x22)
        case "'": return Unicode.Scalar(0x27)
        case "\\": return Unicode.Scalar(0x5C)
        case "/": return Unicode.Scalar(0x2F)
        case "u": return try parseHex(count: 4)
        case "U": return try parseHex(count: 8)
        default:
            throw JSONLD.NQuads.ParseError.invalidEscape(line: line, sequence: "\\\(c)")
        }
    }

    mutating func parseHex(count: Int) throws -> Unicode.Scalar? {
        var v: UInt32 = 0
        for _ in 0..<count {
            guard let c = advance() else {
                throw JSONLD.NQuads.ParseError.invalidEscape(line: line, sequence: "\\u/\\U")
            }
            let digit: UInt32
            switch c {
            case "0"..."9": digit = UInt32(c.value - Unicode.Scalar("0").value)
            case "a"..."f": digit = UInt32(c.value - Unicode.Scalar("a").value) + 10
            case "A"..."F": digit = UInt32(c.value - Unicode.Scalar("A").value) + 10
            default:
                throw JSONLD.NQuads.ParseError.invalidEscape(line: line, sequence: "\\u\(c)")
            }
            v = v &* 16 &+ digit
        }
        return Unicode.Scalar(v)
    }
}

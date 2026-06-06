import Foundation
@testable import JSONLD

/// Walks a JSON-LD document and inlines any string-valued `@context`
/// references against the test suite's on-disk fixtures.
///
/// The expand internals are currently sync; remote-context loading
/// would require propagating `async` through every algorithm path.
/// As a pragmatic workaround for the W3C harness, this pre-pass
/// resolves any string `@context` to the local file under
/// `Tests/JSONLDTests/json-ld-api/tests/<path>` and substitutes the
/// loaded object before calling `JSONLD.expand`.
enum InlineRemoteContexts {
    /// Rewrite `document` so all `@context` strings are replaced with
    /// the loaded inline object. `baseDir` is the directory the
    /// document is served from (used to resolve relative refs).
    static func inline(_ document: JSONLD.JSON, baseDir: URL) throws -> JSONLD.JSON {
        var seen: [String: JSONLD.JSON] = [:]
        return try inline(document, baseDir: baseDir, seen: &seen)
    }

    private static func inline(_ document: JSONLD.JSON, baseDir: URL, seen: inout [String: JSONLD.JSON]) throws -> JSONLD.JSON {
        switch document {
        case .object(var map):
            if let ctxValue = map["@context"] {
                map["@context"] = try inlineContext(ctxValue, baseDir: baseDir, seen: &seen)
            }
            for (k, v) in map where k != "@context" {
                map[k] = try inline(v, baseDir: baseDir, seen: &seen)
            }
            return .object(map)
        case .array(let items):
            return .array(try items.map { try inline($0, baseDir: baseDir, seen: &seen) })
        default:
            return document
        }
    }

    private static func inlineContext(_ ctx: JSONLD.JSON, baseDir: URL, seen: inout [String: JSONLD.JSON]) throws -> JSONLD.JSON {
        switch ctx {
        case .string(let s):
            // Skip URI-shaped strings that aren't local files (e.g.
            // `ex:not:a:context` used inside @type:@json literals).
            // The algorithm itself will decide what to do with them.
            if !FileManager.default.fileExists(atPath: URL(fileURLWithPath: s, relativeTo: baseDir).path) {
                return ctx
            }
            let url = URL(fileURLWithPath: s, relativeTo: baseDir)
            let key = url.absoluteString
            if let cached = seen[key] { return cached }
            seen[key] = .object([:])
            let loaded = try JSONFixture.load(url)
            let nextBase = url.deletingLastPathComponent()
            let resolved: JSONLD.JSON
            if case .object(let m) = loaded, let inner = m["@context"] {
                resolved = try inlineContext(inner, baseDir: nextBase, seen: &seen)
            } else if case .array = loaded {
                // Loaded doc is a JSON-LD document (array), not a
                // context — leave the string @context untouched so
                // processContext surfaces invalidRemoteContext. ter05.
                seen.removeValue(forKey: key)
                return ctx
            } else {
                resolved = loaded
            }
            seen[key] = resolved
            return resolved
        case .array(let arr):
            return .array(try arr.map { try inlineContext($0, baseDir: baseDir, seen: &seen) })
        case .object(var m):
            // Resolve @import (1.1) by inlining the referenced context
            // file's @context into the surrounding map, with the map's
            // existing entries overriding the imported ones.
            if case .string(let importPath) = m["@import"] ?? .null {
                let url = URL(fileURLWithPath: importPath, relativeTo: baseDir)
                if FileManager.default.fileExists(atPath: url.path) {
                    let imported = try JSONFixture.load(url)
                    if case .object(let im) = imported,
                       case .object(let inner) = im["@context"] ?? .null
                    {
                        m.removeValue(forKey: "@import")
                        var merged = inner
                        for (k, v) in m { merged[k] = v }
                        m = merged
                    }
                }
            }
            var out: [String: JSONLD.JSON] = [:]
            for (k, v) in m {
                if k == "@context" {
                    out[k] = try inlineContext(v, baseDir: baseDir, seen: &seen)
                } else if case .object(let inner) = v {
                    out[k] = try inlineContext(.object(inner), baseDir: baseDir, seen: &seen)
                } else {
                    out[k] = v
                }
            }
            return .object(out)
        default:
            return ctx
        }
    }
}

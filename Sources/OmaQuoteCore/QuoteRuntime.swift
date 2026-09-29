import Foundation
import JavaScriptCore

public struct Quote: Equatable {
    public let text: String
    public let attribution: String?
}

public enum QuoteRuntimeError: Error, LocalizedError {
    case missingResource(String)
    case javascript(String)
    case invalidCollection(String)
    case missingResult(String)

    public var errorDescription: String? {
        switch self {
        case .missingResource(let name): "Missing bundled resource: \(name)"
        case .javascript(let message): "JavaScript error: \(message)"
        case .invalidCollection(let message): "Invalid Quote Collection: \(message)"
        case .missingResult(let function): "No result from \(function)"
        }
    }
}

/// Runs OmaQuote's state machine. Confine each instance to one thread: JSContext is not Sendable.
public final class QuoteRuntime {
    private let context: JSContext
    private var model: JSValue?

    public init() throws {
        guard let context = JSContext() else {
            throw QuoteRuntimeError.javascript("Could not create a JavaScript context")
        }
        self.context = context
        try loadScript("JsonDocuments")
        try loadScript("QuoteEngine")
    }

    public static func bundledCollection() throws -> String {
        guard let url = Bundle.module.url(forResource: "quotes", withExtension: "json", subdirectory: "Resources") else {
            throw QuoteRuntimeError.missingResource("quotes.json")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    public var currentQuote: Quote? {
        guard let quote = model?.forProperty("activeQuote"), !quote.isNull, !quote.isUndefined,
              let text = quote.forProperty("text")?.toString() else { return nil }
        let attribution = quote.forProperty("attribution")
        return Quote(text: text, attribution: attribution?.isUndefined == false ? attribution?.toString() : nil)
    }

    public func initialize(collectionJSON: String, randomValues: [Double]? = nil) throws {
        let parsed = try invoke("parseCollection", arguments: [collectionJSON])
        guard parsed.forProperty("ok")?.toBool() == true else {
            let message = parsed.forProperty("error")?.forProperty("message")?.toString() ?? "Unknown error"
            throw QuoteRuntimeError.invalidCollection(message)
        }
        let count = Int(parsed.forProperty("value")?.forProperty("quotes")?.forProperty("length")?.toInt32() ?? 0)
        let choices = randomValues ?? (0..<count).map { _ in Double.random(in: 0..<1) }
        let result = try invoke("initialize", arguments: [parsed.forProperty("value") as Any, ["randomValues": choices]])
        model = try resultModel(result, function: "initialize")
    }

    public func next(randomValues: [Double]? = nil, source: String = "explicit") throws {
        let current = try currentModel()
        let count = Int(current.forProperty("quotes")?.forProperty("length")?.toInt32() ?? 0)
        let choices = randomValues ?? (0..<count).map { _ in Double.random(in: 0..<1) }
        let result = try invoke("advance", arguments: [current, choices, source])
        model = try resultModel(result, function: "advance")
    }

    public func previous() throws {
        let result = try invoke("previous", arguments: [currentModel()])
        model = try resultModel(result, function: "previous")
    }

    public func pause() throws {
        let result = try invoke("pauseAutomaticAdvance", arguments: [currentModel()])
        model = try resultModel(result, function: "pauseAutomaticAdvance")
    }

    public func resume() throws {
        let result = try invoke("resumeAutomaticAdvance", arguments: [currentModel()])
        model = try resultModel(result, function: "resumeAutomaticAdvance")
    }

    public func statusJSON() throws -> String {
        try invoke("runtimeStatus", arguments: [currentModel()]).toString()
    }

    private func loadScript(_ name: String) throws {
        guard let url = Bundle.module.url(forResource: name, withExtension: "js", subdirectory: "Resources") else {
            throw QuoteRuntimeError.missingResource("\(name).js")
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        // The first line is a QML-only directive; the rest is plain JavaScript.
        let script = source.hasPrefix(".pragma library\n") ? String(source.dropFirst(".pragma library\n".count)) : source
        context.evaluateScript(script, withSourceURL: url)
        try checkException()
    }

    private func invoke(_ function: String, arguments: [Any]) throws -> JSValue {
        guard let callable = context.objectForKeyedSubscript(function), !callable.isUndefined else {
            throw QuoteRuntimeError.missingResult(function)
        }
        let result = callable.call(withArguments: arguments)
        try checkException()
        guard let result, !result.isUndefined else { throw QuoteRuntimeError.missingResult(function) }
        return result
    }

    private func currentModel() throws -> JSValue {
        guard let model else { throw QuoteRuntimeError.missingResult("initialize") }
        return model
    }

    private func resultModel(_ result: JSValue, function: String) throws -> JSValue {
        guard let model = result.forProperty("model"), !model.isUndefined else {
            throw QuoteRuntimeError.missingResult(function)
        }
        return model
    }

    private func checkException() throws {
        guard let exception = context.exception else { return }
        context.exception = nil
        throw QuoteRuntimeError.javascript(exception.toString())
    }
}

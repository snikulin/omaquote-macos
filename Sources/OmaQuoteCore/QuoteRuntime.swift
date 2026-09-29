import Foundation
import JavaScriptCore

public struct Quote: Equatable {
    public let text: String
    public let attribution: String?
}

public enum QuoteEffectKind: Equatable {
    case updatePresentation
    case persistState
    case restartInterval
    case stopInterval
}

public enum QuoteEffect: Equatable {
    case updatePresentation(Quote?)
    case persistState(String, recoverHealthOnSave: Bool)
    case restartInterval(minutes: Int)
    case stopInterval

    public var kind: QuoteEffectKind {
        switch self {
        case .updatePresentation: .updatePresentation
        case .persistState: .persistState
        case .restartInterval: .restartInterval
        case .stopInterval: .stopInterval
        }
    }
}

public enum QuoteRuntimeError: Error, LocalizedError {
    case missingResource(String)
    case javascript(String)
    case invalidCollection(String)
    case invalidConfiguration(String)
    case invalidState(String)
    case missingResult(String)

    public var errorDescription: String? {
        switch self {
        case .missingResource(let name): "Missing bundled resource: \(name)"
        case .javascript(let message): "JavaScript error: \(message)"
        case .invalidCollection(let message): "Invalid Quote Collection: \(message)"
        case .invalidConfiguration(let message): "Invalid configuration: \(message)"
        case .invalidState(let message): "Invalid persisted state: \(message)"
        case .missingResult(let function): "No result from \(function)"
        }
    }
}

/// Runs OmaQuote's state machine. Confine each instance to one thread: JSContext is not Sendable.
public final class QuoteRuntime {
    private let context: JSContext
    private var model: JSValue?
    private var configuration: JSValue?

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

    public static func bundledConfiguration() throws -> String {
        guard let url = Bundle.module.url(forResource: "default-config", withExtension: "json", subdirectory: "Resources") else {
            throw QuoteRuntimeError.missingResource("default-config.json")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    public var currentQuote: Quote? {
        quote(from: model?.forProperty("activeQuote"))
    }

    @discardableResult
    public func initialize(
        collectionJSON: String,
        configurationJSON: String? = nil,
        persistedStateJSON: String? = nil,
        collectionKind: String = "bundled",
        collectionError: String? = nil,
        configurationError: String? = nil,
        stateError: String? = nil,
        randomValues: [Double]? = nil
    ) throws -> [QuoteEffect] {
        let collection = try parse("parseCollection", raw: collectionJSON, error: QuoteRuntimeError.invalidCollection)
        let configuration = try effectiveConfiguration(configurationJSON)
        let state = try persistedStateJSON.map {
            try parse("parseState", raw: $0, error: QuoteRuntimeError.invalidState)
        }
        let choices = randomValues ?? randomChoices(for: collection)
        guard let options = JSValue(newObjectIn: context) else {
            throw QuoteRuntimeError.javascript("Could not create engine options")
        }
        options.setValue(choices, forProperty: "randomValues")
        options.setValue(configuration, forProperty: "configuration")
        if let state { options.setValue(state, forProperty: "persistedState") }
        options.setValue(collectionKind, forProperty: "collectionKind")
        if let collectionError { options.setValue(collectionError, forProperty: "collectionError") }
        if let configurationError { options.setValue(configurationError, forProperty: "configurationError") }
        if let stateError { options.setValue(stateError, forProperty: "stateError") }
        let result = try invoke("initialize", arguments: [collection, options])
        let effects = try applyResult(result, function: "initialize")
        self.configuration = configuration
        return effects
    }

    @discardableResult
    public func next(randomValues: [Double]? = nil, source: String = "explicit") throws -> [QuoteEffect] {
        let current = try currentModel()
        let choices = randomValues ?? randomChoices(for: current)
        let result = try invoke("advance", arguments: [current, choices, source])
        return try applyResult(result, function: "advance")
    }

    @discardableResult
    public func previous() throws -> [QuoteEffect] {
        let result = try invoke("previous", arguments: [currentModel()])
        return try applyResult(result, function: "previous")
    }

    @discardableResult
    public func pause() throws -> [QuoteEffect] {
        let result = try invoke("pauseAutomaticAdvance", arguments: [currentModel()])
        return try applyResult(result, function: "pauseAutomaticAdvance")
    }

    @discardableResult
    public func resume() throws -> [QuoteEffect] {
        let result = try invoke("resumeAutomaticAdvance", arguments: [currentModel()])
        return try applyResult(result, function: "resumeAutomaticAdvance")
    }

    @discardableResult
    public func reloadCollection(
        collectionJSON: String, kind: String = "user", randomValues: [Double]? = nil
    ) throws -> [QuoteEffect] {
        let current = try currentModel()
        let collection: JSValue
        do {
            collection = try parse("parseCollection", raw: collectionJSON, error: QuoteRuntimeError.invalidCollection)
        } catch QuoteRuntimeError.invalidCollection(let message) {
            let result = try invoke("collectionReloadFailed", arguments: [current, message])
            return try applyResult(result, function: "collectionReloadFailed")
        }
        let options: [String: Any] = [
            "collectionKind": kind,
            "randomValues": randomValues ?? randomChoices(for: collection)
        ]
        let result = try invoke("reloadCollection", arguments: [current, collection, options])
        return try applyResult(result, function: "reloadCollection")
    }

    @discardableResult
    public func reloadConfiguration(configurationJSON: String) throws -> [QuoteEffect] {
        let current = try currentModel()
        let parsed: JSValue
        do {
            parsed = try effectiveConfiguration(configurationJSON)
        } catch QuoteRuntimeError.invalidConfiguration(let message) {
            let result = try invoke("configurationReloadFailed", arguments: [current, message])
            return try applyResult(result, function: "configurationReloadFailed")
        }
        let randomValues = randomChoices(for: current)
        let result = try invoke("reloadConfiguration", arguments: [current, parsed, randomValues])
        let effects = try applyResult(result, function: "reloadConfiguration")
        configuration = parsed
        return effects
    }

    public func configurationJSON() throws -> String {
        guard let configuration else {
            throw QuoteRuntimeError.missingResult("configuration")
        }
        return try stringify(configuration)
    }

    public func defaultConfigurationJSON() throws -> String {
        try stringify(effectiveConfiguration(nil))
    }

    private func stringify(_ value: JSValue) throws -> String {
        guard let stringify = context.objectForKeyedSubscript("JSON")?.forProperty("stringify"),
              let result = stringify.call(withArguments: [value])?.toString() else {
            throw QuoteRuntimeError.missingResult("JSON.stringify")
        }
        try checkException()
        return result
    }

    public func validateCollection(_ raw: String) throws {
        _ = try parse("parseCollection", raw: raw, error: QuoteRuntimeError.invalidCollection)
    }

    public func validateConfiguration(_ raw: String) throws {
        _ = try effectiveConfiguration(raw)
    }

    private func effectiveConfiguration(_ userJSON: String?) throws -> JSValue {
        let bundledJSON = try Self.bundledConfiguration()
        let defaults = try parse("parseConfiguration", raw: bundledJSON, error: QuoteRuntimeError.invalidConfiguration)
        guard let userJSON else { return defaults }

        // Validate the original text first so duplicate keys and unknown fields stay rejected.
        _ = try parse("parseConfiguration", raw: userJSON, error: QuoteRuntimeError.invalidConfiguration)
        guard var merged = try JSONSerialization.jsonObject(with: Data(bundledJSON.utf8)) as? [String: Any],
              let overrides = try JSONSerialization.jsonObject(with: Data(userJSON.utf8)) as? [String: Any] else {
            throw QuoteRuntimeError.invalidConfiguration("Configuration must be an object")
        }
        for (field, value) in overrides { merged[field] = value }
        let mergedData = try JSONSerialization.data(withJSONObject: merged)
        return try parse(
            "parseConfiguration", raw: String(decoding: mergedData, as: UTF8.self),
            error: QuoteRuntimeError.invalidConfiguration
        )
    }

    public func validateState(_ raw: String) throws {
        _ = try parse("parseState", raw: raw, error: QuoteRuntimeError.invalidState)
    }

    @discardableResult
    public func observeWallpaper(pathSignature: String) throws -> [QuoteEffect] {
        let current = try currentModel()
        let randomValues = randomChoices(for: current)
        return try transition("observeWallpaper", arguments: [pathSignature, randomValues])
    }

    @discardableResult
    public func rebaselineWallpaper(pathSignature: String) throws -> [QuoteEffect] {
        try currentModel().setValue(NSNull(), forProperty: "wallpaperBaseline")
        try checkException()
        return try observeWallpaper(pathSignature: pathSignature)
    }

    @discardableResult
    public func wallpaperUnavailable(_ message: String) throws -> [QuoteEffect] {
        try transition("wallpaperUnavailable", arguments: [message])
    }

    @discardableResult
    public func setVisibility(_ visible: Bool) throws -> [QuoteEffect] {
        try transition("setRuntimeVisibility", arguments: [visible])
    }

    @discardableResult
    public func toggleVisibility() throws -> [QuoteEffect] {
        try transition("toggleRuntimeVisibility")
    }

    @discardableResult
    public func togglePause() throws -> [QuoteEffect] {
        try transition("toggleAutomaticAdvancePause")
    }

    @discardableResult
    public func persistenceFailed(_ message: String) throws -> [QuoteEffect] {
        try transition("persistenceFailed", arguments: [message])
    }

    @discardableResult
    public func persistenceSucceeded() throws -> [QuoteEffect] {
        try transition("persistenceSucceeded")
    }

    @discardableResult
    public func intervalFailed(_ message: String) throws -> [QuoteEffect] {
        try transition("intervalFailed", arguments: [message])
    }

    @discardableResult
    public func intervalSucceeded() throws -> [QuoteEffect] {
        try transition("intervalSucceeded")
    }

    @discardableResult
    public func setPresentationOverflow(_ overflowing: Bool) throws -> [QuoteEffect] {
        try transition("setPresentationOverflow", arguments: [overflowing])
    }

    private func transition(_ function: String, arguments: [Any] = []) throws -> [QuoteEffect] {
        let result = try invoke(function, arguments: [currentModel()] + arguments)
        return try applyResult(result, function: function)
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

    private func parse(
        _ function: String,
        raw: String,
        error: (String) -> QuoteRuntimeError
    ) throws -> JSValue {
        let result = try invoke(function, arguments: [raw])
        guard result.forProperty("ok")?.toBool() == true,
              let value = result.forProperty("value") else {
            let message = result.forProperty("error")?.forProperty("message")?.toString() ?? "Unknown error"
            throw error(message)
        }
        return value
    }

    private func currentModel() throws -> JSValue {
        guard let model else { throw QuoteRuntimeError.missingResult("initialize") }
        return model
    }

    private func randomChoices(for value: JSValue) -> [Double] {
        let count = Int(value.forProperty("quotes")?.forProperty("length")?.toInt32() ?? 0)
        return (0..<count).map { _ in Double.random(in: 0..<1) }
    }

    private func resultModel(_ result: JSValue, function: String) throws -> JSValue {
        guard let model = result.forProperty("model"), !model.isUndefined else {
            throw QuoteRuntimeError.missingResult(function)
        }
        return model
    }

    private func quote(from value: JSValue?) -> Quote? {
        guard let value, !value.isNull, !value.isUndefined,
              let text = value.forProperty("text")?.toString() else { return nil }
        let attribution = value.forProperty("attribution")
        return Quote(text: text, attribution: attribution?.isUndefined == false ? attribution?.toString() : nil)
    }

    private func applyResult(_ result: JSValue, function: String) throws -> [QuoteEffect] {
        let nextModel = try resultModel(result, function: function)
        guard let effectsValue = result.forProperty("effects"), !effectsValue.isUndefined,
              let count = effectsValue.forProperty("length")?.toInt32() else {
            throw QuoteRuntimeError.missingResult("\(function).effects")
        }
        var effects: [QuoteEffect] = []
        for index in 0..<Int(count) {
            guard let effect = effectsValue.atIndex(index),
                  let type = effect.forProperty("type")?.toString() else {
                throw QuoteRuntimeError.missingResult("\(function).effects[\(index)]")
            }
            switch type {
            case "update-presentation":
                effects.append(.updatePresentation(quote(from: effect.forProperty("quote"))))
            case "persist-state":
                guard let state = effect.forProperty("state") else {
                    throw QuoteRuntimeError.missingResult("persist-state.state")
                }
                let serialized = try invoke("serializeState", arguments: [state])
                guard serialized.forProperty("ok")?.toBool() == true,
                      let text = serialized.forProperty("value")?.toString() else {
                    throw QuoteRuntimeError.javascript("Could not serialize persisted state")
                }
                effects.append(.persistState(text, recoverHealthOnSave: effect.forProperty("recoverHealthOnSave")?.toBool() == true))
            case "restart-interval":
                effects.append(.restartInterval(minutes: Int(effect.forProperty("intervalMinutes")?.toInt32() ?? 0)))
            case "stop-interval":
                effects.append(.stopInterval)
            default:
                throw QuoteRuntimeError.javascript("Unknown engine effect: \(type)")
            }
        }
        model = nextModel
        return effects
    }

    private func checkException() throws {
        guard let exception = context.exception else { return }
        context.exception = nil
        throw QuoteRuntimeError.javascript(exception.toString())
    }
}

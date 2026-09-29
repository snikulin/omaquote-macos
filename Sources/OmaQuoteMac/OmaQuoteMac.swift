import AppKit
import OmaQuoteCore

@main
@MainActor
struct OmaQuoteMac {
    static func main() throws {
        if CommandLine.arguments.contains("--self-test") {
            try selfTest()
            print("OmaQuoteCore self-test passed")
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = OmaQuoteAppDelegate()
        app.delegate = delegate
        app.run()
    }

    private static func selfTest() throws {
        let bundled = try QuoteRuntime()
        try bundled.initialize(collectionJSON: QuoteRuntime.bundledCollection(), randomValues: [0, 0, 0])
        precondition(bundled.currentQuote != nil)

        let runtime = try QuoteRuntime()
        let collection = """
            {"version":1,"quotes":[{"text":"First"},{"text":"Second"},{"text":"Third"}]}
            """
        try runtime.initialize(collectionJSON: collection, randomValues: [0, 0])
        let first = runtime.currentQuote
        try runtime.next(randomValues: [0, 0])
        let second = runtime.currentQuote
        precondition(second != first)
        try runtime.pause()
        try runtime.next(randomValues: [0, 0], source: "interval")
        precondition(runtime.currentQuote == second)
        try runtime.previous()
        precondition(runtime.currentQuote == first)
        try runtime.next(randomValues: [0, 0])
        precondition(runtime.currentQuote == second)

        let invalid = try QuoteRuntime()
        do {
            try invalid.initialize(collectionJSON: """
                {"version":1,"version":1,"quotes":[{"text":"One"}]}
                """)
            preconditionFailure("Duplicate JSON key should be rejected")
        } catch QuoteRuntimeError.invalidCollection {
            // Expected: the same strict validation as in OmaQuote.
        }
    }
}

@MainActor
private final class OmaQuoteAppDelegate: NSObject, NSApplicationDelegate {
    private var host: QuoteHost?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let host = QuoteHost()
            try host.start()
            self.host = host
        } catch {
            let alert = NSAlert()
            alert.messageText = "OmaQuote could not start"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        host?.stop()
    }
}

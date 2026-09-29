import Foundation
import OmaQuoteCore

@main
struct OmaQuoteCLI {
    static let commands: Set<String> = [
        "next", "previous", "pause", "resume", "togglePause",
        "show", "hide", "toggle", "reload", "status"
    ]

    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count <= 1, arguments.first.map({ commands.contains($0) }) ?? true else {
            fail("Usage: omaquote [next|previous|pause|resume|togglePause|show|hide|toggle|reload|status]")
        }
        let command = arguments.first
        do {
            if command == nil {
                try launchApp()
                return
            }
            let socket = QuoteFileStore().stateURL.deletingLastPathComponent()
                .appendingPathComponent("command.sock").path
            let response: String
            if let existing = try? UnixCommandClient.send(command!, to: socket) {
                response = existing
            } else {
                try launchApp()
                var received: String?
                for _ in 0..<80 {
                    if let result = try? UnixCommandClient.send(command!, to: socket) {
                        received = result
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.1)
                }
                guard let received else { throw CLIError.appDidNotStart }
                response = received
            }
            if response.hasPrefix("error:") || response == "unknown-command" || response == "not-ready" {
                fail(response)
            }
            print(response)
        } catch { fail(error.localizedDescription) }
    }

    private static func launchApp() throws {
        let application: URL
        if let override = ProcessInfo.processInfo.environment["OMAQUOTE_APP_PATH"] {
            application = URL(fileURLWithPath: override)
        } else {
            let binary = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            var directory = binary.deletingLastPathComponent()
            while directory.path != "/" && directory.pathExtension != "app" {
                directory.deleteLastPathComponent()
            }
            guard directory.pathExtension == "app" else { throw CLIError.appNotFound }
            application = directory
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", application.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CLIError.appDidNotStart }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}

private enum CLIError: Error, LocalizedError {
    case appNotFound
    case appDidNotStart

    var errorDescription: String? {
        switch self {
        case .appNotFound: "OmaQuote.app is not next to this command; set OMAQUOTE_APP_PATH for development"
        case .appDidNotStart: "OmaQuote did not become ready"
        }
    }
}

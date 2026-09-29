import AppKit
import OmaQuoteCore

@MainActor
final class QuotePopoverController: NSViewController {
    private unowned let host: QuoteHost
    private let quoteView = NSTextView()
    private let errorLabel = NSTextField(labelWithString: "")
    private let previousButton = NSButton()
    private let pauseButton = NSButton()
    private let visibilityButton = NSButton()

    init(host: QuoteHost) {
        self.host = host
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 340))
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])

        quoteView.isEditable = false
        quoteView.isSelectable = true
        quoteView.drawsBackground = false
        quoteView.font = NSFont.systemFont(ofSize: 15)
        quoteView.textContainerInset = NSSize(width: 4, height: 4)
        let scroll = NSScrollView()
        scroll.documentView = quoteView
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 175).isActive = true
        stack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        errorLabel.textColor = .systemRed
        errorLabel.font = NSFont.systemFont(ofSize: 11)
        errorLabel.maximumNumberOfLines = 2
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.isHidden = true
        stack.addArrangedSubview(errorLabel)
        errorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let controls = NSStackView()
        controls.orientation = .horizontal
        controls.spacing = 8
        previousButton.title = "Previous"
        previousButton.target = self
        previousButton.action = #selector(previous)
        pauseButton.title = "Pause"
        pauseButton.target = self
        pauseButton.action = #selector(togglePause)
        let nextButton = NSButton(title: "Next", target: self, action: #selector(next))
        controls.addArrangedSubview(previousButton)
        controls.addArrangedSubview(pauseButton)
        controls.addArrangedSubview(nextButton)
        stack.addArrangedSubview(controls)

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 6
        visibilityButton.title = "Hide"
        visibilityButton.target = self
        visibilityButton.action = #selector(toggleVisibility)
        actions.addArrangedSubview(visibilityButton)
        actions.addArrangedSubview(NSButton(title: "Config…", target: self, action: #selector(openConfiguration)))
        actions.addArrangedSubview(NSButton(title: "Reload", target: self, action: #selector(reload)))
        actions.addArrangedSubview(NSButton(title: "Quit", target: self, action: #selector(quit)))
        stack.addArrangedSubview(actions)

        view = root
    }

    func refresh(quote: Quote?, canPrevious: Bool, paused: Bool, error: String?, visible: Bool) {
        loadViewIfNeeded()
        if let quote {
            quoteView.string = quote.attribution.map { "\(quote.text)\n\n— \($0)" } ?? quote.text
        } else {
            quoteView.string = "No Quote in the active collection."
        }
        previousButton.isEnabled = canPrevious
        pauseButton.title = paused ? "Resume" : "Pause"
        visibilityButton.title = visible ? "Hide" : "Show"
        errorLabel.stringValue = error ?? ""
        errorLabel.isHidden = error == nil
    }

    @objc private func previous() { _ = host.execute("previous") }
    @objc private func togglePause() { _ = host.execute("togglePause") }
    @objc private func next() { _ = host.execute("next") }
    @objc private func toggleVisibility() { _ = host.execute("toggle") }
    @objc private func reload() { _ = host.execute("reload") }
    @objc private func openConfiguration() { host.openConfiguration() }
    @objc private func quit() { NSApp.terminate(nil) }
}

import AppKit
import GrizzyBotCore

/// Shows an MCP server's question (`elicitation/create`) as a modal form.
@MainActor
enum McpElicitationPrompt {
    static func install() {
        McpOAuth.openBrowser = { url in
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
        McpElicitation.handler = { message, fields in
            await MainActor.run { ask(message: message, fields: fields) }
        }
    }

    private static func ask(message: String, fields: [McpElicitationField]) -> McpElicitationReply {
        let alert = NSAlert()
        alert.messageText = "An MCP server is asking"
        alert.informativeText = message.isEmpty ? "The server needs more information to continue." : message
        alert.addButton(withTitle: "Submit")
        alert.addButton(withTitle: "Decline")
        alert.addButton(withTitle: "Cancel")

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        var readers: [(String, () -> String)] = []
        for f in fields {
            let label = NSTextField(labelWithString: f.title + (f.required ? " *" : "") + (f.detail.isEmpty ? "" : " — \(f.detail)"))
            label.lineBreakMode = .byTruncatingTail
            stack.addArrangedSubview(label)
            if f.type == "boolean" {
                let box = NSButton(checkboxWithTitle: f.title, target: nil, action: nil)
                stack.addArrangedSubview(box)
                readers.append((f.key, { box.state == .on ? "true" : "false" }))
            } else if !f.options.isEmpty {
                let pop = NSPopUpButton(frame: .zero, pullsDown: false)
                pop.addItems(withTitles: f.options)
                stack.addArrangedSubview(pop)
                readers.append((f.key, { pop.titleOfSelectedItem ?? "" }))
            } else {
                let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 22))
                field.widthAnchor.constraint(equalToConstant: 320).isActive = true
                stack.addArrangedSubview(field)
                readers.append((f.key, { field.stringValue }))
            }
        }
        if !fields.isEmpty {
            stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
            alert.accessoryView = stack
        }
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            var values: [String: String] = [:]
            for (key, read) in readers {
                let v = read()
                if !v.isEmpty { values[key] = v }
            }
            return .accept(values)
        case .alertSecondButtonReturn: return .decline
        default: return .cancel
        }
    }
}

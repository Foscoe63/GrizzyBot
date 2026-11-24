import Foundation

/// Turns a `ComputerInput` into the argument list for a program inside a Private desktop. Pure, so the mapping is
/// testable without a container. Every list is passed to `podman exec` as separate arguments, never through a shell, and
/// text from a bot always follows a `--`, so it cannot be read as an option.
public enum XdotoolCommands {
    /// One JPEG of the whole screen on stdout. The base image has ffmpeg with `x11grab`, so the layer needs no screenshot tool.
    public static let screenshot = [
        "ffmpeg", "-loglevel", "error", "-f", "x11grab", "-i", PodmanDesktop.display,
        "-frames:v", "1", "-q:v", "5", "-f", "image2pipe", "-vcodec", "mjpeg", "-",
    ]

    /// Wheel clicks are about this many pixels of page, so a model's pixel delta becomes a sensible number of them.
    static let pixelsPerWheelClick = 50.0
    static let maxWheelClicks = 40

    /// A point from a screenshot, kept on the screen. Nil for a value that is not a number.
    static func pixel(_ value: Double, limit: Int) -> Int? {
        guard value.isFinite else { return nil }
        return min(max(Int(value.rounded()), 0), max(limit - 1, 0))
    }

    public static func arguments(for input: ComputerInput, frame: ComputerScreenFrame) -> [String]? {
        switch input.kind {
        case .click, .rightClick, .doubleClick:
            guard let x = pixel(input.x, limit: frame.pixelWidth), let y = pixel(input.y, limit: frame.pixelHeight) else { return nil }
            let button = input.kind == .rightClick ? "3" : "1"
            let repeats = input.kind == .doubleClick ? ["--repeat", "2", "--delay", "80"] : []
            return ["xdotool", "mousemove", "--sync", String(x), String(y), "click"] + repeats + [button]
        case .scroll:
            guard let x = pixel(input.x, limit: frame.pixelWidth), let y = pixel(input.y, limit: frame.pixelHeight) else { return nil }
            let delta = Double(input.text.trimmingCharacters(in: .whitespaces)) ?? 120
            guard delta.isFinite, delta != 0 else { return nil }
            let clicks = min(max(Int((abs(delta) / pixelsPerWheelClick).rounded()), 1), maxWheelClicks)
            // X maps the wheel to buttons 4 (up) and 5 (down).
            return ["xdotool", "mousemove", "--sync", String(x), String(y),
                    "click", "--repeat", String(clicks), "--delay", "30", delta > 0 ? "5" : "4"]
        case .type:
            guard !input.text.isEmpty else { return nil }
            return ["xdotool", "type", "--clearmodifiers", "--delay", "12", "--", input.text]
        case .key:
            guard let chord = keyChord(input.text) else { return nil }
            return ["xdotool", "key", "--clearmodifiers", "--", chord]
        case .open:
            return openArguments(input.text)
        }
    }

    // MARK: Keys

    private static let modifiers: [String: String] = [
        "ctrl": "ctrl", "control": "ctrl",
        // A Linux desktop's shortcuts (copy, paste, select all) are on Ctrl, so a model that says cmd+c means ctrl+c.
        "cmd": "ctrl", "command": "ctrl", "meta": "ctrl",
        "alt": "alt", "opt": "alt", "option": "alt",
        "shift": "shift",
        "super": "super", "win": "super", "windows": "super",
    ]

    private static let namedKeys: [String: String] = [
        "enter": "Return", "return": "Return", "escape": "Escape", "esc": "Escape", "tab": "Tab",
        "space": "space", "backspace": "BackSpace",
        // On Linux this is the forward-delete key; "backspace" is the one that deletes backwards.
        "delete": "Delete", "del": "Delete",
        "up": "Up", "down": "Down", "left": "Left", "right": "Right",
        "home": "Home", "end": "End", "pageup": "Prior", "pagedown": "Next", "insert": "Insert",
        "plus": "plus", "minus": "minus", "comma": "comma", "period": "period", "slash": "slash",
    ]

    private static let symbolKeys: [Character: String] = [
        "+": "plus", "-": "minus", ",": "comma", ".": "period", "/": "slash", " ": "space",
    ]

    /// `cmd+c`, `shift+enter`, `Escape`, `ctrl++` → xdotool's `ctrl+c`, `shift+Return`, `Escape`, `ctrl+plus`. Nil when
    /// any part is not a key we know, so nothing odd reaches xdotool.
    public static func keyChord(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        var parts = text.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        // "ctrl++" splits into ["ctrl", "", ""]: the empty tail is the plus key itself.
        if parts.count >= 2, parts.last == "", parts[parts.count - 2] == "" { parts.removeLast(2); parts.append("+") }
        if parts == ["", ""] { parts = ["+"] }
        guard !parts.isEmpty, parts.count <= 5, !parts.contains("") else { return nil }

        var mapped: [String] = []
        for (index, part) in parts.enumerated() {
            let lowered = part.lowercased()
            if index < parts.count - 1 {
                guard let modifier = modifiers[lowered] else { return nil }
                mapped.append(modifier)
            } else {
                guard let key = keyName(part) else { return nil }
                mapped.append(key)
            }
        }
        return mapped.joined(separator: "+")
    }

    private static func keyName(_ part: String) -> String? {
        let lowered = part.lowercased()
        if let named = namedKeys[lowered] { return named }
        if part.count == 1, let character = part.first {
            if character.isASCII, character.isLetter || character.isNumber { return String(character) }
            return symbolKeys[character]
        }
        // F1 to F12.
        if lowered.hasPrefix("f"), let number = Int(lowered.dropFirst()), (1...12).contains(number) { return "F\(number)" }
        return nil
    }

    // MARK: Open

    /// Opens a web page in the desktop's Firefox. Only http and https: a bot cannot start `file:` or `javascript:` this way.
    public static func openArguments(_ raw: String) -> [String]? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return ["firefox", url.absoluteString]
    }
}

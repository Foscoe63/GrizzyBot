import Foundation

/// One thing the person did in the browser while teaching a bot.
public struct DemoEvent: Sendable, Equatable {
    public enum Kind: String, Sendable { case click, type, select, key, navigate }
    public var kind: Kind
    /// What the person saw: a button's text, a field's label or placeholder.
    public var label: String
    /// button, link, field, menu, checkbox, …
    public var role: String
    /// Typed text or the chosen option. Empty for a sensitive field: the value is never sent here at all.
    public var value: String
    public var url: String
    public var sensitive: Bool

    public init(kind: Kind, label: String = "", role: String = "", value: String = "", url: String = "", sensitive: Bool = false) {
        self.kind = kind; self.label = label; self.role = role; self.value = value; self.url = url; self.sensitive = sensitive
    }

    /// Reads the message the page script posts. Anything that does not look like one is dropped.
    public static func parse(_ raw: Any?) -> DemoEvent? {
        guard let object = raw as? [String: Any], let kindRaw = object["k"] as? String,
              let kind = Kind(rawValue: kindRaw) else { return nil }
        func text(_ key: String, _ limit: Int) -> String { String((object[key] as? String ?? "").prefix(limit)) }
        return DemoEvent(kind: kind, label: text("label", 120), role: text("role", 24), value: text("value", 500), url: text("url", 500),
                         sensitive: object["sensitive"] as? Bool ?? false)
    }
}

/// What a recording becomes: plain steps a bot can follow, with nothing secret in them.
public struct DemoRecorder: Sendable, Equatable {
    public static let maxSteps = 150
    public private(set) var steps: [DemoEvent] = []

    public init() {}

    public var isEmpty: Bool { steps.isEmpty }

    /// Adds an event, folding repeats: typing in one field is one step with the final text, a repeated click or visit is
    /// one step. A sensitive value is dropped here even if the page script sent it.
    public mutating func add(_ event: DemoEvent) {
        var event = event
        event.url = Self.cleanURL(event.url)
        if event.sensitive || (event.kind == .type && MemoryLedger.looksLikeSecret(event.value)) {
            event.sensitive = true
            event.value = ""
        }
        // A label that names a private thing ("Password", "API token") is kept out too: the skill scanner refuses those words,
        // and a login demonstration must still be saveable.
        if MemoryLedger.looksLikeSecret(event.label) { event.label = event.kind == .type ? "private" : "sign-in" }
        if let last = steps.last {
            if event.kind == .type, last.kind == .type, last.label == event.label, last.role == event.role {
                steps[steps.count - 1] = event
                return
            }
            if event.kind == .navigate, last.kind == .navigate, last.url == event.url { return }
            if event.kind == last.kind, event.label == last.label, event.role == last.role, event.value == last.value, event.kind != .type { return }
        }
        guard steps.count < Self.maxSteps else { return }
        steps.append(event)
    }

    /// Host and path only: a query string or fragment can hold a token or a session.
    public static func cleanURL(_ raw: String) -> String {
        guard var parts = URLComponents(string: raw) else { return "" }
        parts.query = nil
        parts.fragment = nil
        parts.user = nil
        parts.password = nil
        return parts.string ?? ""
    }

    /// The page script that reports what a person does. Runs in its own content world, so a page cannot see it or fake a report.
    public static let pageScript = #"""
    (function () {
      if (window.__gbDemoInstalled) return; window.__gbDemoInstalled = true;
      var SENSITIVE = /pass|pwd|otp|token|secret|card|cvv|cvc|ssn|2fa|one-time|security/i;
      function post(o) { try { window.webkit.messageHandlers.grizzyDemo.postMessage(o); } catch (e) {} }
      function text(el) { return ((el.getAttribute('aria-label') || el.innerText || el.value || el.getAttribute('title') || '') + '').replace(/\s+/g, ' ').trim().slice(0, 100); }
      function fieldLabel(el) {
        var l = el.getAttribute('aria-label') || el.placeholder || el.name || el.id || '';
        if (!l && el.labels && el.labels[0]) l = el.labels[0].innerText;
        return (l + '').replace(/\s+/g, ' ').trim().slice(0, 100);
      }
      function role(el) {
        var r = el.getAttribute('role'); if (r) return r;
        var t = el.tagName.toLowerCase();
        if (t === 'a') return 'link'; if (t === 'button' || (t === 'input' && /button|submit/.test(el.type))) return 'button';
        if (t === 'select') return 'menu'; if (t === 'input' && el.type === 'checkbox') return 'checkbox';
        if (t === 'input' && el.type === 'radio') return 'radio'; if (t === 'input' || t === 'textarea') return 'field';
        return 'element';
      }
      function isSensitive(el) {
        var s = (el.type === 'password') || /password|one-time-code|cc-/.test(el.autocomplete || '') || SENSITIVE.test((el.name || '') + ' ' + (el.id || '') + ' ' + (el.placeholder || ''));
        return !!s;
      }
      document.addEventListener('click', function (e) {
        if (!e.isTrusted) return;
        var el = e.target.closest && e.target.closest('a,button,input,select,textarea,summary,[role=button],[role=link],[role=tab],[role=menuitem],label') || e.target;
        if (!el || !el.tagName) return;
        var t = el.tagName.toLowerCase();
        if (t === 'input' && !/button|submit|checkbox|radio/.test(el.type)) return;
        if (t === 'textarea' || t === 'select') return;
        post({ k: 'click', label: t === 'input' && /checkbox|radio/.test(el.type) ? fieldLabel(el) : text(el), role: role(el), url: location.href });
      }, true);
      document.addEventListener('change', function (e) {
        if (!e.isTrusted) return;
        var el = e.target; if (!el || !el.tagName) return;
        var t = el.tagName.toLowerCase();
        if (t === 'select') post({ k: 'select', label: fieldLabel(el), role: 'menu', value: (el.options[el.selectedIndex] || {}).text || '', url: location.href });
        else if (t === 'input' || t === 'textarea') {
          if (/checkbox|radio|button|submit/.test(el.type)) return;
          var s = isSensitive(el);
          post({ k: 'type', label: fieldLabel(el), role: 'field', value: s ? '' : (el.value || ''), sensitive: s, url: location.href });
        }
      }, true);
      document.addEventListener('keydown', function (e) {
        if (!e.isTrusted) return;
        if (e.key === 'Enter' || e.key === 'Escape') post({ k: 'key', label: e.key, role: 'key', url: location.href });
      }, true);
      if (window.top === window) post({ k: 'navigate', url: location.href });
    })();
    """#
}

/// Turns a recording into a skill a bot can follow.
public enum DemoPlaybook {
    public static func describe(_ step: DemoEvent) -> String {
        let label = step.label.isEmpty ? "" : " “\(step.label)”"
        switch step.kind {
        case .navigate:
            return "Go to \(step.url.isEmpty ? "the page" : step.url)."
        case .click:
            return "Click the \(step.role.isEmpty ? "element" : step.role)\(label)."
        case .select:
            return "In the\(label) menu, choose “\(step.value)”."
        case .key:
            return "Press \(step.label)."
        case .type:
            if step.sensitive {
                return "In the\(label) field, enter the value the person gives you. This was a private field and was not recorded. Ask the person for it, or request a takeover so they type it; never guess it."
            }
            return step.value.isEmpty ? "Clear the\(label) field." : "In the\(label) field, type “\(step.value)” (what was typed in the demonstration; use the right value for this job)."
        }
    }

    /// The skill's id, one-line description and body.
    public static func render(title: String, steps: [DemoEvent]) -> (id: String, description: String, body: String) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = cleanTitle.isEmpty ? "Recorded task" : cleanTitle
        let host = steps.compactMap { URL(string: $0.url)?.host }.first
        let description = "\(name) in the browser\(host.map { " on \($0)" } ?? ""), recorded from a demonstration."
        var lines = [
            "# \(name)",
            "",
            "A person showed this task in the browser and it was written down as steps. Follow them in order; the page may look different today, so find each control by its visible label rather than its position.",
            "",
            "## Steps",
        ]
        for (index, step) in steps.enumerated() {
            lines.append("\(index + 1). \(describe(step))")
        }
        lines += [
            "",
            "## If it does not match",
            "- Take a screenshot (or read the page outline) before each click, and adapt if a label has changed.",
            "- Stop and tell the person what differs if a step would do something the demonstration did not show.",
            "- Never type a private value (a login, a code, a card number) from memory. Ask the person for it, or request a takeover.",
        ]
        return (SkillMarkdown.slug(name), description, lines.joined(separator: "\n"))
    }
}

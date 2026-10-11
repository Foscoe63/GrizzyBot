import Foundation

/// A skill is text that gets pasted into a model's instructions and can ask it to run commands, so an
/// imported one deserves the same suspicion as a downloaded script. This is a static screen, not a
/// guarantee: it catches the obvious (and the lazily disguised), and says what it found.
public struct SkillScanReport: Sendable, Equatable {
    public enum Risk: Int, Sendable, Comparable, Codable {
        case clean = 0, caution = 1, danger = 2

        public static func < (a: Risk, b: Risk) -> Bool { a.rawValue < b.rawValue }

        public var label: String {
            switch self {
            case .clean: return "No issues found"
            case .caution: return "Review before enabling"
            case .danger: return "Looks dangerous"
            }
        }
    }

    public struct Finding: Sendable, Equatable {
        public var risk: Risk
        public var rule: String
        public var detail: String
    }

    public var findings: [Finding]

    public var risk: Risk { findings.map(\.risk).max() ?? .clean }

    public var summary: String {
        guard !findings.isEmpty else { return Risk.clean.label }
        return findings.map { "• \($0.detail)" }.joined(separator: "\n")
    }
}

public enum SkillScanner {
    private struct Rule {
        var id: String
        var risk: SkillScanReport.Risk
        var detail: String
        var pattern: String
    }

    private static let rules: [Rule] = [
        Rule(id: "pipe-to-shell", risk: .danger, detail: "Downloads something and pipes it into a shell",
             pattern: #"(curl|wget|fetch)\b[^\n|]*\|\s*(sudo\s+)?(ba|z|da)?sh\b"#),
        Rule(id: "decode-and-run", risk: .danger, detail: "Decodes hidden text and runs it",
             pattern: #"(base64\s+(-d|--decode|-D)|xxd\s+-r|openssl\s+enc\s+-d)[^\n]*\|\s*(ba|z|da)?sh\b|eval\s*\(?\s*\$\(\s*(echo|printf)[^)]*base64"#),
        Rule(id: "destructive-rm", risk: .danger, detail: "Deletes whole directories (rm -rf on /, ~, or $HOME)",
             pattern: #"rm\s+-[a-zA-Z]*[rR][a-zA-Z]*\s+(/|~/?|\$\{?HOME\}?/?)(\*|\s|$)"#),
        Rule(id: "credential-paths", risk: .danger, detail: "Reaches for credentials (~/.ssh, ~/.aws, Keychain, browser logins)",
             pattern: #"(~|\$HOME|/Users/[^/\s]+)/(\.ssh|\.aws|\.gnupg|\.kube|\.docker|Library/Keychains|Library/Application Support/(Google/Chrome|Firefox))|security\s+(find|dump)-(generic|internet)-password|login\.keychain"#),
        Rule(id: "reverse-shell", risk: .danger, detail: "Opens a remote shell",
             pattern: #"(nc|ncat|netcat)\s+[^\n]*-e\s|/dev/tcp/|bash\s+-i\s+>&|mkfifo\s+[^\n]*\|\s*(nc|ncat)"#),
        Rule(id: "injection-override", risk: .danger, detail: "Tells the model to ignore its instructions",
             pattern: #"(?i)(ignore|disregard|forget)\s+(all\s+|any\s+|your\s+|the\s+)?(previous|prior|above|earlier|system)\s+(instructions|prompts?|rules|messages)"#),
        Rule(id: "injection-secrecy", risk: .danger, detail: "Tells the model to hide what it is doing from the person",
             pattern: #"(?i)(do\s+not|don'?t|never)\s+(tell|inform|mention|show|reveal)[^\n.]{0,40}(user|person|human|owner)|without\s+(telling|informing|notifying)\s+(the\s+)?(user|person)"#),
        Rule(id: "exfiltration", risk: .danger, detail: "Sends data to an outside address",
             pattern: #"(?i)(curl|wget|http\s+post|fetch)[^\n]*(-d|--data|--upload-file|-F)\s[^\n]*(\.env|id_rsa|credentials|token|secret|password|memory\.md)"#),
        Rule(id: "sudo", risk: .caution, detail: "Asks for administrator rights (sudo)",
             pattern: #"(^|\s)sudo\s"#),
        Rule(id: "persistence", risk: .caution, detail: "Installs something that keeps running (launch agent, cron, login item)",
             pattern: #"LaunchAgents|LaunchDaemons|launchctl\s+(load|bootstrap)|crontab\s+-|osascript[^\n]*login item"#),
        Rule(id: "keystrokes", risk: .caution, detail: "Types keystrokes or clicks through the UI via AppleScript",
             pattern: #"osascript[^\n]*(keystroke|key code|click)"#),
        Rule(id: "disable-safety", risk: .caution, detail: "Mentions turning off approvals or safety checks",
             pattern: #"(?i)(disable|skip|bypass|turn\s+off)\s+(the\s+)?(approval|confirmation|safety|sandbox|policy|permission)"#),
        Rule(id: "long-blob", risk: .caution, detail: "Contains a long opaque encoded blob",
             pattern: #"[A-Za-z0-9+/]{240,}={0,2}"#),
    ]

    private static let broadTools: Set<String> = [
        "shell", "shell.exec", "computer_click", "computer_type", "computer_key", "plugin_call",
        "destination_write", "mcp_call", "delete_file", "spawn_bot", "message_bot",
    ]

    public static func scan(_ skill: AgentSkill) -> SkillScanReport {
        scan(text: skill.body + "\n" + skill.description, allowedTools: skill.allowedTools)
    }

    public static func scan(text: String, allowedTools: [String] = []) -> SkillScanReport {
        var findings: [SkillScanReport.Finding] = []
        for rule in rules {
            if text.range(of: rule.pattern, options: .regularExpression) != nil {
                findings.append(.init(risk: rule.risk, rule: rule.id, detail: rule.detail))
            }
        }
        if hasHiddenCharacters(text) {
            findings.append(.init(
                risk: .danger, rule: "hidden-text",
                detail: "Contains invisible or direction-flipping characters that can hide instructions"
            ))
        }
        let broad = allowedTools.filter { broadTools.contains($0) }
        if !broad.isEmpty {
            findings.append(.init(
                risk: .caution, rule: "broad-tools",
                detail: "Asks for powerful tools: \(broad.sorted().joined(separator: ", "))"
            ))
        }
        return SkillScanReport(findings: findings)
    }

    /// Zero-width characters, bidi overrides, and tag characters — none of which belong in a playbook.
    static func hasHiddenCharacters(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2064, 0x2066...0x2069, 0xFEFF, 0xE0000...0xE007F:
                return true
            default:
                continue
            }
        }
        return false
    }
}

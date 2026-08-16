import SwiftUI

/// Lightweight markdown renderer for chat bubbles (HANDOFF §5.5).
struct MarkdownText: View {
    let source: String
    var streaming: Bool = false
    var textColor: Color = Theme.textPrimary
    var fontSize: CGFloat = 15.5
    var lineSpacing: CGFloat = 4

    @State private var cursorOn = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .code(let code):
                    Text(code)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(Theme.bgCode)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                case .heading(let level, let text):
                    attributedLine(text)
                        .font(.system(size: fontSize + CGFloat(4 - min(level, 3)), weight: .semibold))
                        .foregroundStyle(textColor)
                case .bullet(let marker, let text):
                    HStack(alignment: .top, spacing: 8) {
                        Text(marker)
                            .font(.system(size: fontSize))
                            .foregroundStyle(Theme.textSecondary)
                        attributedLine(text)
                            .font(.system(size: fontSize))
                            .foregroundStyle(textColor)
                    }
                    .padding(.leading, 8)
                case .paragraph(let text):
                    attributedLine(text)
                        .font(.system(size: fontSize))
                        .foregroundStyle(textColor)
                        .lineSpacing(lineSpacing)
                }
            }
            if streaming {
                Text("▍")
                    .font(.system(size: fontSize, design: .monospaced))
                    .foregroundStyle(textColor)
                    .opacity(cursorOn ? 1 : 0.15)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                            cursorOn.toggle()
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private func attributedLine(_ text: String) -> some View {
        if let attr = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attr)
        } else {
            Text(text)
        }
    }

    private enum Block {
        case code(String)
        case heading(Int, String)
        case bullet(String, String)
        case paragraph(String)
    }

    private var blocks: [Block] {
        var result: [Block] = []
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("```") {
                i += 1
                var codeLines: [String] = []
                while i < lines.count, !lines[i].hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                if i < lines.count { i += 1 }
                result.append(.code(codeLines.joined(separator: "\n")))
                continue
            }
            if line.hasPrefix("### ") {
                result.append(.heading(3, String(line.dropFirst(4))))
            } else if line.hasPrefix("## ") {
                result.append(.heading(2, String(line.dropFirst(3))))
            } else if line.hasPrefix("# ") {
                result.append(.heading(1, String(line.dropFirst(2))))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                result.append(.bullet("•", String(line.dropFirst(2))))
            } else if let match = line.firstMatch(of: /^(\d+)\.\s+(.*)$/) {
                result.append(.bullet("\(match.1).", String(match.2)))
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                // skip blank separators
            } else {
                result.append(.paragraph(line))
            }
            i += 1
        }
        return result
    }
}

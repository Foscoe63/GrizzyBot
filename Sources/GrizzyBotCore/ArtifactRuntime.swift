import Foundation

/// Builds the document an artifact renders inside, and names the bundled
/// runtimes it needs.
///
/// Everything the frame loads comes from `ArtifactRuntime.scheme`, served out
/// of the app bundle. Nothing reaches the network: the policy below closes
/// `connect-src`, and the web view's navigation delegate cancels any load that
/// is not this scheme. Artifact content is carried in as base64 and decoded in
/// the page, so no amount of quoting in model output can break out of the
/// script that receives it.
public enum ArtifactRuntime {
    public static let scheme = "grizzy-artifact"
    public static let host = "frame"

    /// Files served from `Resources/ArtifactRuntime` in the app bundle.
    public enum Runtime: String, CaseIterable, Sendable {
        case react = "react.js"
        case reactDOM = "react-dom.js"
        case babel = "babel.js"
        case mermaid = "mermaid.js"
        case tailwind = "tailwind.js"
    }

    public static let contentSecurityPolicy = [
        "default-src 'none'",
        "script-src 'self' 'unsafe-inline' 'unsafe-eval'",
        "style-src 'self' 'unsafe-inline'",
        "img-src 'self' data: blob:",
        "font-src 'self' data:",
        "media-src 'self' data: blob:",
        "connect-src 'none'",
        "form-action 'none'",
        "base-uri 'none'",
        "frame-src 'none'",
        "object-src 'none'",
    ].joined(separator: "; ")

    public static func url(for path: String) -> URL? {
        URL(string: "\(scheme)://\(host)/\(path)")
    }

    public static var indexURL: URL? { url(for: "index.html") }

    /// The document for one artifact. `dark` only sets the frame's own
    /// chrome — artifact content styles itself.
    public static func document(for record: ArtifactRecord, dark: Bool) -> String {
        switch record.kind {
        case .html:
            return htmlDocument(record.content, dark: dark)
        case .svg:
            return shell(body: "<div id=\"root\" class=\"center\"></div>", boot: svgBoot(record.content), scripts: [], dark: dark)
        case .mermaid:
            return shell(
                body: "<div id=\"root\" class=\"center\"></div>",
                boot: mermaidBoot(record.content, dark: dark),
                scripts: [.mermaid],
                dark: dark
            )
        case .react:
            return shell(
                body: "<div id=\"root\"></div>",
                boot: reactBoot(record.content),
                scripts: [.tailwind, .react, .reactDOM, .babel],
                dark: dark
            )
        case .markdown, .code:
            // Rendered natively; a document is only ever asked for as a fallback.
            return shell(body: "<div id=\"root\" class=\"center\"></div>", boot: svgBoot(""), scripts: [], dark: dark)
        }
    }

    // MARK: - Raw HTML artifacts

    /// An HTML artifact is its own document, so it is served intact rather than
    /// rebuilt — only the policy and the Tailwind runtime are injected, so a
    /// page written against Tailwind classes still looks right offline.
    static func htmlDocument(_ raw: String, dark: Bool) -> String {
        let injected = """
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
        <script src="\(Runtime.tailwind.rawValue)"></script>
        """
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()

        if let range = lowered.range(of: "<head>") {
            return trimmed.replacingCharacters(in: range, with: "<head>\(injected)")
        }
        if let range = lowered.range(of: "<html") {
            // `<html …>` with no head — open one right after the tag closes.
            let afterTag = trimmed[range.lowerBound...]
            if let close = afterTag.firstIndex(of: ">") {
                let insertion = trimmed.index(after: close)
                return trimmed.replacingCharacters(
                    in: insertion..<insertion,
                    with: "<head>\(injected)</head>"
                )
            }
        }
        return """
        <!doctype html>
        <html>
        <head>\(injected)\(frameStyle(dark: dark))</head>
        <body>\(trimmed)</body>
        </html>
        """
    }

    // MARK: - Generated documents

    static func shell(body: String, boot: String, scripts: [Runtime], dark: Bool) -> String {
        let tags = scripts.map { "<script src=\"\($0.rawValue)\"></script>" }.joined(separator: "\n")
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
        \(frameStyle(dark: dark))
        \(tags)
        </head>
        <body>
        \(body)
        <script>
        \(errorReporter)
        \(boot)
        </script>
        </body>
        </html>
        """
    }

    static func frameStyle(dark: Bool) -> String {
        let fg = dark ? "#e8e6e3" : "#1a1a1a"
        let bg = dark ? "#1c1b1a" : "#ffffff"
        return """
        <style>
        html, body { margin: 0; padding: 0; background: \(bg); color: \(fg);
          font: 14px -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif; }
        .center { display: flex; align-items: center; justify-content: center;
          min-height: 100vh; padding: 16px; box-sizing: border-box; }
        .center svg { max-width: 100%; height: auto; }
        .artifact-error { margin: 0; padding: 16px 18px; font: 12.5px ui-monospace, SFMono-Regular, Menlo, monospace;
          white-space: pre-wrap; color: #ff9d8a; background: rgba(255, 90, 60, 0.09);
          border-left: 3px solid #ff6b4a; border-radius: 6px; }
        </style>
        """
    }

    /// Shared by every boot script: failures land in the frame instead of a
    /// silent blank page, because a blank artifact reads as "the app is broken".
    static let errorReporter = """
    function artifactFail(heading, detail) {
      var host = document.getElementById('root') || document.body;
      var box = document.createElement('pre');
      box.className = 'artifact-error';
      box.textContent = heading + (detail ? '\\n\\n' + detail : '');
      host.classList.remove('center');
      host.textContent = '';
      host.appendChild(box);
    }
    function artifactSource(b64) {
      return new TextDecoder().decode(Uint8Array.from(atob(b64), function (c) { return c.charCodeAt(0); }));
    }
    window.addEventListener('error', function (e) {
      artifactFail('This artifact stopped with an error.', e.message);
    });
    """

    static func svgBoot(_ content: String) -> String {
        """
        (function () {
          var source = artifactSource("\(base64(content))");
          // innerHTML never executes inserted <script> tags, which is the
          // behaviour we want for SVG that arrived from a model.
          document.getElementById('root').innerHTML = source;
        })();
        """
    }

    static func mermaidBoot(_ content: String, dark: Bool) -> String {
        """
        (function () {
          var source = artifactSource("\(base64(content))");
          if (typeof mermaid === 'undefined') {
            artifactFail('The diagram runtime did not load.');
            return;
          }
          mermaid.initialize({ startOnLoad: false, theme: '\(dark ? "dark" : "default")', securityLevel: 'strict' });
          mermaid.render('artifact-diagram', source).then(function (out) {
            document.getElementById('root').innerHTML = out.svg;
          }).catch(function (err) {
            artifactFail('This diagram could not be drawn.', String(err && err.message ? err.message : err));
          });
        })();
        """
    }

    /// Transforms JSX in the page with Babel, then mounts the default export.
    /// Imports resolve against the bundled runtimes only; anything else fails
    /// loudly and names what is available, which is more useful than a blank
    /// frame and a console the user cannot see.
    static func reactBoot(_ content: String) -> String {
        """
        (function () {
          var source = artifactSource("\(base64(content))");
          if (typeof Babel === 'undefined' || typeof React === 'undefined' || typeof ReactDOM === 'undefined') {
            artifactFail('The React runtime did not load.');
            return;
          }
          var compiled;
          try {
            compiled = Babel.transform(source, {
              presets: [['react', { runtime: 'classic' }]],
              plugins: ['transform-modules-commonjs'],
              filename: 'artifact.jsx'
            }).code;
          } catch (err) {
            artifactFail('This artifact could not be compiled.', String(err && err.message ? err.message : err));
            return;
          }
          var available = { 'react': React, 'react-dom': ReactDOM, 'react-dom/client': ReactDOM };
          function require(name) {
            if (available[name]) { return available[name]; }
            throw new Error(
              "This artifact imports '" + name + "', which GrizzyBot does not bundle.\\n" +
              'Available imports: react, react-dom. Rewrite the artifact without ' + name + '.'
            );
          }
          var module = { exports: {} };
          try {
            new Function('require', 'module', 'exports', 'React', 'ReactDOM', compiled)(
              require, module, module.exports, React, ReactDOM
            );
          } catch (err) {
            artifactFail('This artifact failed while loading.', String(err && err.message ? err.message : err));
            return;
          }
          var Component = module.exports.default || module.exports;
          if (typeof Component !== 'function') {
            artifactFail(
              'This artifact has no default export to render.',
              'End the file with: export default function App() { … }'
            );
            return;
          }
          try {
            ReactDOM.createRoot(document.getElementById('root')).render(React.createElement(Component));
          } catch (err) {
            artifactFail('This artifact failed while rendering.', String(err && err.message ? err.message : err));
          }
        })();
        """
    }

    static func base64(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }
}

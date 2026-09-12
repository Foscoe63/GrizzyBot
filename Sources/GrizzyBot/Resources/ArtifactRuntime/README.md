# Artifact runtime

Vendored, unmodified browser builds served to the artifact WKWebView by
`ArtifactSchemeHandler`. They are bundled rather than fetched so an artifact
frame can run with the network fully closed (`connect-src 'none'`, and a
navigation delegate that cancels every load off the custom scheme).

| File            | Package                     | Version  | License |
|-----------------|-----------------------------|----------|---------|
| `react.js`      | react (UMD, production)     | 18.3.1   | MIT     |
| `react-dom.js`  | react-dom (UMD, production) | 18.3.1   | MIT     |
| `babel.js`      | @babel/standalone           | 7.26.4   | MIT     |
| `mermaid.js`    | mermaid (dist)              | 11.4.1   | MIT     |
| `tailwind.js`   | tailwindcss browser build   | 3.4.16   | MIT     |

React is pinned to 18 because React 19 no longer publishes UMD builds, and the
frame loads these as plain scripts with no bundler.

To refresh a file, download the same artifact from its CDN and replace it in
place — nothing here is patched.

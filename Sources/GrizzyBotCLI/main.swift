import Foundation
import GrizzyBotCore

setvbuf(stdout, nil, _IOLBF, 0)
let parsed = HeadlessCLI.parse(Array(CommandLine.arguments.dropFirst()), env: ProcessInfo.processInfo.environment)

func finish(_ text: String, _ code: HeadlessCLI.ExitCode, toStderr: Bool = false) -> Never {
    FileHandle.standardError.write(Data(((toStderr ? text : "") + (toStderr ? "\n" : "")).utf8))
    if !toStderr { print(text) }
    exit(code.rawValue)
}

switch parsed {
case .help: finish(HeadlessCLI.usage, .ok)
case .error(let message): finish("\(message)\n\n\(HeadlessCLI.usage)", .usage, toStderr: true)
case .run(let inv):
    guard !inv.token.isEmpty else {
        finish("No token. Pass --token or set GRIZZYBOT_TOKEN (shown in GrizzyBot's control-plane settings).", .unauthorized, toStderr: true)
    }
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(inv.port)/mcp")!)
    request.httpMethod = "POST"
    request.httpBody = HeadlessCLI.requestBody(for: inv)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(inv.token)", forHTTPHeaderField: "Authorization")
    // The app may wait up to 120s for a reply; allow a little longer.
    request.timeoutInterval = 150
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var outcome: (Int, Data)?
    URLSession.shared.dataTask(with: request) { data, response, _ in
        if let http = response as? HTTPURLResponse { outcome = (http.statusCode, data ?? Data()) }
        done.signal()
    }.resume()
    done.wait()
    guard let (status, body) = outcome else {
        finish("Can't reach GrizzyBot on port \(inv.port). Is the app open with the control plane turned on?", .unreachable, toStderr: true)
    }
    let result = HeadlessCLI.interpret(status: status, body: body, json: inv.json)
    finish(result.output, result.code, toStderr: result.code != .ok)
}

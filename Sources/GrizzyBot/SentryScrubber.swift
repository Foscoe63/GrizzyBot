#if canImport(Sentry)
import Sentry
#endif
import GrizzyBotCore

#if canImport(Sentry)
enum SentryScrubber {
    static func scrub(_ event: Event) -> Event? {
        if let message = event.message?.formatted {
            event.message = SentryMessage(formatted: DiagnosticScrubber.redact(message))
        }
        event.extra = redactDictionary(event.extra)
        event.tags = event.tags?.mapValues { DiagnosticScrubber.redact($0) }
        if let crumbs = event.breadcrumbs {
            for crumb in crumbs {
                if let message = crumb.message {
                    crumb.message = DiagnosticScrubber.redact(message)
                }
                if let data = crumb.data {
                    let scrubbed = DiagnosticScrubber.redactAny(data) as? [String: Any] ?? [:]
                    for key in data.keys where scrubbed[key] == nil {
                        crumb.setData(value: nil, key: key)
                    }
                    for (key, value) in scrubbed {
                        crumb.setData(value: value, key: key)
                    }
                }
            }
        }
        if let request = event.request {
            let scrubbed = request
            scrubbed.headers = request.headers?.mapValues { DiagnosticScrubber.redact($0) }
            scrubbed.url = request.url.map { DiagnosticScrubber.redact($0) }
            event.request = scrubbed
        }
        if let exceptions = event.exceptions {
            for exception in exceptions {
                if let value = exception.value {
                    exception.value = DiagnosticScrubber.redact(value)
                }
            }
        }
        return event
    }

    private static func redactDictionary(_ dict: [String: Any]?) -> [String: Any]? {
        guard let dict else { return nil }
        var next: [String: Any] = [:]
        for (key, value) in dict {
            if let string = value as? String {
                next[key] = DiagnosticScrubber.redact(string)
            } else {
                next[key] = DiagnosticScrubber.redactAny(value)
            }
        }
        return next
    }
}
#endif

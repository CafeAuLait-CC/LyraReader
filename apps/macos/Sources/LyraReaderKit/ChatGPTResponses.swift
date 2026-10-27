import LyraReaderBindings
import Foundation

/// Converts the locally prepared context into the exact, previewed Responses payload. The
/// endpoint and request shape are OpenAI's documented Responses API; the credential is a Sign in
/// with ChatGPT OAuth token, which is why it is sent only to the fixed official endpoint and
/// never to a user-editable API base URL. Sign in with ChatGPT is a preview contract with its own
/// documented limitations (for example: no Files upload API), and it can change. Failures are
/// therefore surfaced as real errors, never silently downgraded to a text-only request.
///
/// The Responses API takes each user message's `content` as an array of content parts. Text is
/// `input_text`; a region capture is `input_image` with an inline PNG `data:` URL. The body is
/// rendered by the Rust builder, which owns the exact bytes and encodes the capture once. The
/// previewed `wire_body` is the body that is sent.
/// A ChatGPT stream failure that already knows its stable category.
///
/// Carrying the category on the error is what keeps the audit trail from matching message text.
fileprivate struct ChatGPTStreamFailure: LocalizedError {
    let message: String
    let code: AiErrorCode

    var errorDescription: String? { message }
}

@MainActor
package enum ChatGPTResponses {
    package static let endpoint = "https://api.openai.com/v1/responses"

    package static func plan(_ source: AiPlanRecord) throws -> AiPlanRecord {
        var plan = source
        plan.endpoint = endpoint
        plan.temperature = nil
        plan.maxTokens = nil
        for part in plan.parts {
            guard let image = part.image else { continue }
            guard !image.png.isEmpty, image.widthPx > 0, image.heightPx > 0 else {
                throw AISettingsError.refused(
                    "The region picture is empty, so there is nothing to send.", .emptyContext)
            }
            guard image.png.count <= AIRegionLimits.maximumPNGBytes else {
                throw AISettingsError.invalid(
                    "The region picture is larger than the \(AIRegionLimits.maximumPNGBytes / (1024 * 1024)) MiB attachment bound. Select a smaller region.")
            }
        }
        return try renderAiPlan(plan: plan, transport: .responses)
    }

    /// A non-2xx response is where an account or model that will not take an image shows up.
    /// Name the picture and keep the reason actionable instead of falling back to text, which
    /// would answer a different question from the one the reader approved.
    package static func check(_ response: URLResponse, carryingImage: Bool) throws {
        do {
            try ChatGPTAccountStore.check(response)
        } catch {
            let status = (response as? HTTPURLResponse)?.statusCode
            guard carryingImage, let status else {
                // The account check's messages for 401/403/429 do not carry the numeric status
                // (the old stream classifier therefore said providerError); the default branch
                // does carry "HTTP n" (which it said httpError). Encode the same result.
                let code: AiErrorCode = (status == 401 || status == 403 || status == 429)
                    ? .other : .httpStatus
                throw ChatGPTStreamFailure(message: AIReadableError.message(error), code: code)
            }
            let text: String
            switch status {
            case 401:
                text = "Your ChatGPT session expired before the region image was sent (HTTP 401). Sign in again in Settings > AI, then press Retry; the question is kept."
            case 403:
                text = "ChatGPT plan usage did not authorize this region image (HTTP 403). Check your plan and LyraReader's permission in ChatGPT Settings, then press Retry; the question is kept."
            case 400, 413, 415, 422:
                text = "The ChatGPT plan refused the region image (HTTP \(status)). The selected model may not accept image input; choose a model that accepts images in Settings > AI, then press Retry. The question is kept."
            default:
                throw ChatGPTStreamFailure(message: AIReadableError.message(error), code: .httpStatus)
            }
            throw ChatGPTStreamFailure(
                message: text, code: status == 401 ? .unauthorized : .httpStatus)
        }
    }

    /// Terminal events are explicit: a partial text stream is never treated as a completed answer.
    package static func events(
        _ data: String,
        carryingImage: Bool = false
    ) throws -> (events: [AIStreamEvent], completed: Bool) {
        guard let json = data.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              let type = object["type"] as? String else {
            throw ChatGPTStreamFailure(
                message: "ChatGPT returned a malformed response event.", code: .protocol)
        }
        switch type {
        case "response.output_text.delta":
            return ((object["delta"] as? String).map { [.delta($0)] } ?? [], false)
        case "response.refusal.delta":
            return ((object["delta"] as? String).map { [.delta($0)] } ?? [], false)
        case "response.completed":
            let response = object["response"] as? [String: Any] ?? [:]
            let usage = response["usage"] as? [String: Any] ?? [:]
            let details = usage["output_tokens_details"] as? [String: Any] ?? [:]
            return ([.usage(AIUsage(promptTokens: usage["input_tokens"] as? Int,
                                    completionTokens: usage["output_tokens"] as? Int,
                                    totalTokens: usage["total_tokens"] as? Int,
                                    reasoningTokens: details["reasoning_tokens"] as? Int))], true)
        case "response.failed", "response.incomplete", "error":
            let response = object["response"] as? [String: Any] ?? [:]
            let error = response["error"] as? [String: Any] ?? object["error"] as? [String: Any] ?? object
            let code = error["code"] as? String ?? ""
            let text: String
            switch code {
            case "subscription_sharing_usage_limit_exceeded": text = "The ChatGPT plan usage limit was reached. Review app usage in ChatGPT Settings > Usage."
            case "subscription_sharing_usage_unavailable": text = "ChatGPT plan usage is unavailable. Review your plan and LyraReader's permission in ChatGPT Settings."
            default:
                if type == "response.incomplete" {
                    text = "ChatGPT returned an incomplete answer. The partial answer is kept."
                } else if carryingImage {
                    text = "ChatGPT failed the request that carried the region image\(code.isEmpty ? "" : " (\(code))"). If the selected model does not accept image input, choose one that does in Settings > AI, then press Retry. The partial answer is kept."
                } else {
                    text = "ChatGPT could not complete this request. The partial answer is kept; check your account and retry."
                }
            }
            throw ChatGPTStreamFailure(message: text, code: .other)
        default: return ([], false)
        }
    }
}

@MainActor
final class ChatGPTResponsesHandle: AIChatHandle {
    private var task: Task<Void, Never>?
    private var pending: [AIStreamEvent] = []
    private(set) var isFinished = false
    private let id = UUID()
    private let accounts: ChatGPTAccountStore

    init(plan: AiPlanRecord, accounts: ChatGPTAccountStore, accountID: UUID) {
        self.accounts = accounts
        accounts.registerRequest(id) { [weak self] in self?.cancel() }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                for part in plan.parts {
                    try Task.checkCancellation()
                    let carriesImage = part.image != nil
                    let token = try await accounts.accessToken(for: accountID)
                    try Task.checkCancellation()
                    pending.append(.partStarted(index: Int(part.index), total: Int(part.total), label: part.label))
                    var request = URLRequest(url: URL(string: ChatGPTResponses.endpoint)!)
                    request.httpMethod = "POST"; request.timeoutInterval = 120
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    guard !part.wireBody.isEmpty else {
                        throw ChatGPTStreamFailure(
                            message: "The ChatGPT request was not prepared for the Responses transport. Nothing was sent.",
                            code: .other)
                    }
                    request.httpBody = Data(part.wireBody.utf8)
                    let (bytes, response) = try await accounts.session.bytes(for: request)
                    try ChatGPTResponses.check(response, carryingImage: carriesImage)
                    var completed = false
                    var decoder = ChatGPTEventDecoder()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        if let event = try decoder.push(byte) {
                            let parsed = try ChatGPTResponses.events(event, carryingImage: carriesImage)
                            pending.append(contentsOf: parsed.events)
                            if parsed.completed { completed = true; break }
                        }
                    }
                    guard completed else {
                        throw ChatGPTStreamFailure(
                            message: "The ChatGPT stream ended before completion. The partial answer is kept.",
                            code: .protocol)
                    }
                }
                try Task.checkCancellation()
                pending.append(.done)
            } catch {
                if !isFinished {
                    let cancelled = Task.isCancelled || error is CancellationError
                    let streamFailure = error as? ChatGPTStreamFailure
                    pending.append(.error(
                        message: cancelled ? "Cancelled." : (streamFailure?.message ?? AIReadableError.message(error)),
                        cancelled: cancelled,
                        code: cancelled ? .cancelled : (streamFailure?.code ?? Self.code(for: error))
                    ))
                }
            }
            isFinished = true; accounts.unregisterRequest(id)
        }
    }
    /// The stable category for a transport error that was not already classified.
    ///
    /// Only error *types* and URL error codes are inspected; the old audit classifier looked at
    /// the URLSession message for "connection"/"timed out". These mappings reproduce exactly the
    /// categories it produced for Foundation's messages and leave everything else `.other`.
    private static func code(for error: Error) -> AiErrorCode {
        guard let urlError = error as? URLError else { return .other }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .secureConnectionFailed:
            return .unreachable
        case .timedOut:
            return .timeout
        default:
            return .other
        }
    }

    func poll() -> [AIStreamEvent] { let events = pending; pending.removeAll(); return events }
    func cancel() {
        guard !isFinished else { return }
        task?.cancel(); isFinished = true
        pending.append(.error(message: "Cancelled.", cancelled: true))
        accounts.unregisterRequest(id)
    }
}

/// Foundation's AsyncBytes.lines omits empty lines, which are SSE event boundaries. Decode the
/// bytes explicitly so multiline data, CRLF, split UTF-8, and interrupted streams stay distinct.
package struct ChatGPTEventDecoder {
    private var line: [UInt8] = []
    private var data: [String] = []
    private var frameBytes = 0
    private var previousCR = false

    package init() {}
    package mutating func push(_ byte: UInt8) throws -> String? {
        frameBytes += 1
        guard frameBytes <= 2_000_000 else {
            throw ChatGPTStreamFailure(message: "ChatGPT returned an oversized stream event.", code: .protocol)
        }
        if previousCR && byte == 10 { previousCR = false; return nil }
        previousCR = byte == 13
        if byte == 10 || byte == 13 {
            guard let text = String(bytes: line, encoding: .utf8) else {
                throw ChatGPTStreamFailure(message: "ChatGPT returned invalid stream text.", code: .protocol)
            }
            line.removeAll(keepingCapacity: true)
            if text.isEmpty {
                frameBytes = 0
                guard !data.isEmpty else { return nil }
                let event = data.joined(separator: "\n"); data.removeAll(keepingCapacity: true)
                return event
            }
            if text.hasPrefix("data:") {
                var value = text.dropFirst(5)
                if value.first == " " { value = value.dropFirst() }
                data.append(String(value))
            }
        } else { line.append(byte) }
        return nil
    }
}

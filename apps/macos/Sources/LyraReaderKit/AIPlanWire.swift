import LyraReaderBindings
import Foundation

/// Materialises the one wire body for the connection the reader chose.
///
/// The Rust planner returns a transport-neutral plan: the text parts, the page labels and the
/// exact capture bytes, but no JSON body and no base64. The body is rendered here, once, for
/// exactly one transport. The preview stores that string and the send reuses it, so a large
/// region capture is encoded once rather than once per transport.
@MainActor
package enum AIPlanWire {
    /// Render the plan for `connection`. API-key plans get the chat-completions body; ChatGPT
    /// plans get the fixed Responses body.
    package static func render(
        _ source: AiPlanRecord,
        connection: AIConnectionMode
    ) throws -> AiPlanRecord {
        switch connection {
        case .chatGPT:
            return try ChatGPTResponses.plan(source)
        case .apiKey:
            return try renderAiPlan(plan: source, transport: .chatCompletions)
        }
    }
}

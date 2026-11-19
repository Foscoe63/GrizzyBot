import Foundation

/// Automated messages the loop sends the model, or shows the person, when a turn goes off track.
public enum AgentPrompts {
    // MARK: Reply recovery

    public static func continueAfterLength(tail: String) -> String {
        "[automated] Your last reply hit the output limit and was cut off after: \"\(tail)\". Continue exactly where you left off, with no preamble and no repeating."
    }

    public static let answerAfterTools =
        "[automated] You ran tools but wrote no reply. Using the tool results above, answer the person now in plain text. Do not call more tools unless something essential is missing."

    public static let noAnswerAfterTools =
        "I ran the tools but the model returned no written answer. Ask me to summarize what was found and I'll use the results above."

    // MARK: Loop guard

    public static func guardFailing(tool: String, count: Int) -> String {
        "\(tool) has failed \(count) times with the same arguments. Change the arguments or approach, or tell the person what is stuck."
    }

    public static func guardSameResult(tool: String) -> String {
        "\(tool) keeps returning the same result. Use what you have, try a different approach, or finish."
    }

    public static func guardSimilar(tool: String, count: Int) -> String {
        "You have called \(tool) \(count) times in a row with near-identical arguments. Confirm this is making progress, otherwise change approach or finish."
    }

    public static func guardStopped(reason: String) -> String {
        "I got stuck (\(reason)) without making progress, so I stopped early. Try rephrasing, or ask me to take a different approach."
    }

    // MARK: Compaction

    public static let summarize = """
    You are compacting the earlier part of a working session so it fits in context. Write a faithful summary \
    that lets work continue without the original messages. Keep: the goal and constraints, decisions made, \
    files/paths/IDs/URLs touched, tool results that matter (exact values, errors), what is finished, and what \
    is still open. Drop chatter and repetition. Do not invent anything. Plain text, under 400 words, no preamble.
    """

    public static let summaryNoteHeader = "summarized by you so far; treat as accurate history:]"

    public static let memoryFlush = """
    The conversation is about to be shortened to fit the context window. Anything not saved will be lost.
    If there are durable facts, decisions, preferences, or open commitments above that you will need later, save each with remember (one short fact per call). If nothing is worth keeping, reply with exactly: NOTHING_TO_SAVE
    """
}

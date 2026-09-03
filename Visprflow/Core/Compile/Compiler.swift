import Foundation

/// Compiles a transcript into the text the destination wants, and refuses to insert output
/// that shows a known failure mode.
///
/// The retry ladder is the important part. If the model answers the question, invents a file
/// name or starts writing prose, the output is thrown away and the same transcript is compiled
/// again one level lower. If that also fails, the raw transcript is inserted, because what the
/// user actually said is never wrong.
struct Compiler: PromptCompiling {
    let generator: any TextGenerating
    var guardrails: Guardrails = .default
    /// Whether a rejected attempt is retried at a lower level before falling back to raw text.
    var retriesOnce = true

    init(generator: any TextGenerating, guardrails: Guardrails = .default) {
        self.generator = generator
        self.guardrails = guardrails
    }

    func compile(
        _ request: CompileRequest,
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws -> CompiledPrompt {
        let transcript = request.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            return CompiledPrompt(text: "", level: request.level)
        }
        // Verbatim never reaches a model: that is the whole promise of the level.
        guard request.level != .verbatim else {
            onPartial(transcript)
            return CompiledPrompt(text: transcript, level: .verbatim)
        }

        var attempt = request
        attempt.transcript = transcript
        var firstRejection: String?

        for round in 0...(retriesOnce ? 1 : 0) {
            let generation = GenerationRequest(
                system: SystemPrompt.core,
                user: SystemPrompt.userMessage(for: attempt),
                model: ModelChoice.forLevel(attempt.level),
                maxTokens: SystemPrompt.maxTokens(for: transcript)
            )

            // Each attempt accumulates its own text, so a rejected attempt's partial output
            // is replaced in the overlay rather than appended to.
            let accumulator = PartialText()
            let output: String
            do {
                output = try await generator.generate(generation) { delta in
                    onPartial(accumulator.append(delta))
                }
            } catch is CancellationError {
                throw GenerationError.cancelled
            }

            let verdict = guardrails.check(
                output: output,
                transcript: transcript,
                vocabulary: attempt.vocabulary
            )
            if verdict.passed {
                return CompiledPrompt(
                    text: output.trimmingCharacters(in: .whitespacesAndNewlines),
                    level: attempt.level,
                    usedRawFallback: false,
                    guardrailReason: firstRejection,
                    requestJSON: generation.auditJSON()
                )
            }

            firstRejection = firstRejection ?? verdict.reason
            Log.compile.error("Guardrail rejected \(attempt.level.rawValue, privacy: .public) output: \(verdict.reason ?? "unknown", privacy: .public)")

            let lower = attempt.level.lowered
            // Nothing left to step down to, so stop here and use the transcript.
            if round == 0, lower != attempt.level, lower != .verbatim {
                attempt.level = lower
                continue
            }
            break
        }

        // The floor: what the user said. Never wrong, only unpolished.
        Log.compile.info("Falling back to the raw transcript")
        onPartial(transcript)
        return CompiledPrompt(
            text: transcript,
            level: .verbatim,
            usedRawFallback: true,
            guardrailReason: firstRejection,
            requestJSON: nil
        )
    }
}


/// Accumulates streamed deltas for one attempt.
private final class PartialText: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func append(_ delta: String) -> String {
        lock.lock(); defer { lock.unlock() }
        text += delta
        return text
    }
}

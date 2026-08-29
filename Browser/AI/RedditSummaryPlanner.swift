import Foundation

struct RedditSummaryChunk: Sendable, Equatable {
    let index: Int
    let text: String
    let commentCount: Int
}

struct RedditSummaryPlan: Sendable, Equatable {
    let chunks: [RedditSummaryChunk]
    let characterBudget: Int
    let totalCommentCount: Int

    var chunkCount: Int { chunks.count }
}

/// Pure planning for Reddit map/reduce work. The planner only runs for a
/// context carrying the explicit Reddit coverage marker, so ordinary article
/// and selected-text summaries retain their existing behavior.
enum RedditSummaryPlanner {
    static let coverageMarker = "Reddit coverage:"
    static let commentsMarker = "--- Comments ---"

    // FoundationModels does not expose its tokenizer. This deterministic
    // approximation targets a 7K-token prompt/input window. Reddit comments
    // contain short usernames, punctuation, emoji, and fragmented phrases, so
    // they tokenize more densely than ordinary prose; use a conservative three
    // characters per token. Source records reserve 750 tokens for Reddit
    // instructions, labels, the retry prefix, and framework transcript
    // overhead. This keeps the complete prompt below the model's 8K context
    // while retaining room for up to 320 output tokens. These are budgets, not
    // exact tokenizer measurements.
    static let appleLocalRedditInputTokenBudget = 7_000
    static let appleLocalRedditApproximateCharactersPerToken = 3
    static let appleLocalRedditPromptInstructionTokenReserve = 750
    static let appleLocalRedditPromptCharacterBudget =
        appleLocalRedditInputTokenBudget * appleLocalRedditApproximateCharactersPerToken
    static let appleLocalRedditSourceTokenBudget =
        appleLocalRedditInputTokenBudget - appleLocalRedditPromptInstructionTokenReserve
    static let appleLocalRedditSourceCharacterBudget = max(
        256,
        appleLocalRedditSourceTokenBudget * appleLocalRedditApproximateCharactersPerToken
    )
    // Even very short Reddit replies carry per-comment usernames, scores,
    // punctuation, and reply-depth metadata. Bound the number of comment
    // records in one Apple Local pass so a densely fragmented thread cannot
    // appear character-safe while overflowing the real tokenizer.
    static let appleLocalRedditMaxCommentsPerChunk = 100

    static func isRedditContext(_ text: String) -> Bool {
        text.contains(coverageMarker) && text.range(of: commentsMarker) != nil
    }

    /// Only Apple Local has the direct one-generation Reddit route. Other
    /// providers retain their existing map/reduce execution even when a plan
    /// happens to contain one chunk.
    static func shouldUseSingleGeneration(
        plan: RedditSummaryPlan,
        backend: AIModelBackend
    ) -> Bool {
        backend == .localApple && plan.chunkCount == 1
    }

    /// Returns whether an Apple Local Reddit request needs the guarded
    /// multi-pass choice before any generation starts. This is deliberately
    /// limited to structured Reddit context and the Apple Local backend so
    /// ordinary pages and other providers keep their existing routes.
    static func requiresAppleLocalMultiPassPreflight(
        content: String,
        backend: AIModelBackend
    ) -> Bool {
        guard backend == .localApple, isRedditContext(content) else { return false }
        return plan(content: content, backend: backend).chunkCount > 1
    }

    /// Budgets leave room for provider instructions and the generated answer.
    /// Smaller local models get more map/reduce passes rather than fewer source
    /// comments. Web/PCC budgets stay close to their existing safe windows.
    static func characterBudget(for backend: AIModelBackend) -> Int {
        switch backend {
        case .localApple:
            return appleLocalRedditSourceCharacterBudget
        case .mlxLocal:
            return 8_000
        case .applePCCGateway:
            return 80_000
        case .webChatGPT, .webGemini:
            return 76_000
        case .cloudShortcuts:
            return 60_000
        }
    }

    /// Reduction prompts can safely combine several compact map outputs. Keep
    /// the Apple Local Reddit reduction budget aligned with its input budget so
    /// reductions retain all map outputs without falling back to the ordinary
    /// 8K-character Apple Local cap. Other provider values are unchanged.
    static func reductionCharacterBudget(for backend: AIModelBackend) -> Int {
        switch backend {
        case .localApple:
            return appleLocalRedditSourceCharacterBudget
        case .mlxLocal:
            return 8_000
        case .applePCCGateway:
            return 80_000
        case .webChatGPT, .webGemini:
            return 76_000
        case .cloudShortcuts:
            return 60_000
        }
    }

    static func plan(content: String, backend: AIModelBackend) -> RedditSummaryPlan {
        let budget = max(256, characterBudget(for: backend))
        guard isRedditContext(content),
              let markerRange = content.range(of: commentsMarker) else {
            let text = String(content.prefix(budget))
            return RedditSummaryPlan(
                chunks: text.isEmpty ? [] : [RedditSummaryChunk(index: 0, text: text, commentCount: 0)],
                characterBudget: budget,
                totalCommentCount: 0
            )
        }

        let preamble = String(content[..<markerRange.upperBound])
        let commentText = String(content[markerRange.upperBound...])
        var records: [(text: String, commentCount: Int)] = [(preamble, 0)]

        // RedditAPI formats one comment as one normalized line. Splitting on
        // those boundaries keeps nested replies and later comments intact.
        records.append(contentsOf: commentText
            .split(whereSeparator: \.isNewline)
            .map { (String($0), 1) }
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })

        let chunks = pack(
            records: records,
            budget: budget,
            maxCommentsPerChunk: backend == .localApple ? appleLocalRedditMaxCommentsPerChunk : nil
        )
        return RedditSummaryPlan(
            chunks: chunks,
            characterBudget: budget,
            totalCommentCount: chunks.reduce(0) { $0 + $1.commentCount }
        )
    }

    /// Packs already-generated partial summaries for a reduction pass. Every
    /// input record is represented in order; this helper never keeps only a
    /// prefix or suffix of the collection.
    static func reductionGroups(_ summaries: [String], backend: AIModelBackend) -> [[String]] {
        let budget = max(256, reductionCharacterBudget(for: backend))
        var groups: [[String]] = []
        var current: [String] = []
        var currentCharacters = 0
        for summary in summaries {
            let normalized = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }
            let labeled = "[Partial Reddit summary \(groups.reduce(0) { $0 + $1.count } + current.count + 1)]\n\(normalized)"
            let additional = labeled.count + (current.isEmpty ? 0 : 1)
            if !current.isEmpty, currentCharacters + additional > budget {
                groups.append(current)
                current = []
                currentCharacters = 0
            }
            current.append(labeled)
            currentCharacters += labeled.count + (current.count == 1 ? 0 : 1)
        }
        if !current.isEmpty {
            groups.append(current)
        }
        return groups
    }

    /// Produces the largest safe single prompt for a web provider when a
    /// Reddit thread is larger than the provider's context window. The source
    /// remains ordered, but complete comment records are sampled from the
    /// beginning, middle, and end of the thread so later comments cannot be
    /// silently lost behind a prefix-only truncation. The coverage header is
    /// retained and the compaction is explicitly disclosed to the model.
    ///
    /// Non-Reddit text is returned unchanged. Callers can therefore use this
    /// helper only on Reddit paths without changing ordinary web context
    /// condensation or selected-text behavior.
    static func webSafeContext(content: String, maxCharacters: Int) -> String {
        guard isRedditContext(content) else { return content }
        guard maxCharacters > 0 else { return "" }
        let budget = maxCharacters
        guard content.count > budget,
              let markerRange = content.range(of: commentsMarker) else {
            return content
        }

        let rawPreamble = String(content[..<markerRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let records = String(content[markerRange.upperBound...])
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !records.isEmpty else {
            return String(content.prefix(budget))
        }

        let notice = "[Reddit web context compacted: sampled accessible comments across the full ordered thread; first, middle, and final regions are represented.]"
        let header = [rawPreamble, notice, commentsMarker]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        // Reserve the newline separating the header from the first comment.
        let available = budget - header.count - 1
        guard available > 0 else {
            return String(header.prefix(budget))
        }
        // Keep the output bounded even for an unusually tiny caller budget.
        // A normal web budget is large enough for all three representative
        // records; below that threshold the honest header is the safest form.
        guard available >= min(3, records.count) else {
            return header
        }

        let mandatoryIndices = balancedSampleIndices(count: records.count, sampleCount: min(3, records.count))
        let separatorCost = max(0, mandatoryIndices.count - 1)
        let mandatoryBudget = max(1, available - separatorCost)
        let perMandatoryBudget = max(1, mandatoryBudget / max(1, mandatoryIndices.count))

        var renderedByIndex: [Int: String] = [:]
        var usedCharacters = 0
        for (position, index) in mandatoryIndices.enumerated() {
            let separatorsRemaining = mandatoryIndices.count - position - 1
            let remainingBudget = max(1, available - usedCharacters - separatorsRemaining)
            let recordBudget = min(perMandatoryBudget, remainingBudget)
            let rendered = boundedRecord(records[index], maxCharacters: recordBudget)
            renderedByIndex[index] = rendered
            usedCharacters += rendered.count
            if position < mandatoryIndices.count - 1 {
                usedCharacters += 1
            }
        }

        // Use any remaining capacity for additional records sampled at even
        // intervals. This keeps the payload distributed across the whole
        // ordered thread instead of filling the budget from the beginning.
        let averageRecordCharacters = max(
            1,
            records.reduce(0) { $0 + $1.count } / max(1, records.count)
        )
        let estimatedSampleCount = max(
            mandatoryIndices.count,
            min(records.count, available / max(2, averageRecordCharacters + 1))
        )
        let candidateIndices = balancedSampleIndices(
            count: records.count,
            sampleCount: estimatedSampleCount
        )
        for index in candidateIndices where renderedByIndex[index] == nil {
            let separator = renderedByIndex.isEmpty ? 0 : 1
            let remaining = available - usedCharacters - separator
            guard remaining > 0 else { break }
            guard records[index].count + separator <= remaining else { continue }
            renderedByIndex[index] = records[index]
            usedCharacters += separator + records[index].count
        }

        let selected = renderedByIndex.keys.sorted().compactMap { renderedByIndex[$0] }
        guard !selected.isEmpty else {
            return String(header.prefix(budget))
        }
        return header + "\n" + selected.joined(separator: "\n")
    }

    private static func pack(
        records: [(text: String, commentCount: Int)],
        budget: Int,
        maxCommentsPerChunk: Int?
    ) -> [RedditSummaryChunk] {
        guard !records.isEmpty else { return [] }

        var result: [RedditSummaryChunk] = []
        var currentText: [String] = []
        var currentCharacters = 0
        var currentCommentCount = 0

        func flush() {
            guard !currentText.isEmpty else { return }
            result.append(
                RedditSummaryChunk(
                    index: result.count,
                    text: currentText.joined(separator: "\n"),
                    commentCount: currentCommentCount
                )
            )
            currentText.removeAll(keepingCapacity: true)
            currentCharacters = 0
            currentCommentCount = 0
        }

        for record in records {
            let normalized = record.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }

            if record.commentCount > 0,
               let maxCommentsPerChunk,
               currentCommentCount > 0,
               currentCommentCount + record.commentCount > maxCommentsPerChunk {
                flush()
            }

            // A single long post/comment is split at a character boundary only
            // as a last resort. All pieces are retained and the comment count
            // belongs to the first piece.
            var pieces = splitOversized(normalized, budget: budget)
            if pieces.isEmpty { pieces = [normalized] }
            for (pieceIndex, piece) in pieces.enumerated() {
                let additional = piece.count + (currentText.isEmpty ? 0 : 1)
                if !currentText.isEmpty, currentCharacters + additional > budget {
                    flush()
                }
                currentText.append(piece)
                currentCharacters += piece.count + (currentText.count == 1 ? 0 : 1)
                if pieceIndex == 0 {
                    currentCommentCount += record.commentCount
                }
                if currentCharacters >= budget {
                    flush()
                }
            }
        }
        flush()
        return result
    }

    private static func splitOversized(_ text: String, budget: Int) -> [String] {
        guard text.count > budget else { return [text] }
        var pieces: [String] = []
        var remaining = text
        while remaining.count > budget {
            let hardEnd = remaining.index(remaining.startIndex, offsetBy: budget)
            let candidate = remaining[..<hardEnd]
            let splitIndex = candidate.lastIndex(where: { $0 == " " || $0 == "\t" }) ?? hardEnd
            let end = splitIndex == remaining.startIndex ? hardEnd : splitIndex
            let piece = String(remaining[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { pieces.append(piece) }
            remaining = String(remaining[end...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !remaining.isEmpty { pieces.append(remaining) }
        return pieces
    }

    private static func boundedRecord(_ record: String, maxCharacters: Int) -> String {
        guard record.count > maxCharacters else { return record }
        guard maxCharacters > 1 else { return String(record.prefix(maxCharacters)) }
        return String(record.prefix(maxCharacters - 1)) + "…"
    }

    private static func balancedSampleIndices(count: Int, sampleCount: Int) -> [Int] {
        guard count > 0 else { return [] }
        let target = max(1, min(count, sampleCount))
        guard target > 1 else { return [0] }
        return (0..<target).map { position in
            Int((Double(position) * Double(count - 1) / Double(target - 1)).rounded())
        }
    }
}

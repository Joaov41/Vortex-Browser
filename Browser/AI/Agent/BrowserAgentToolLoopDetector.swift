//
//  BrowserAgentToolLoopDetector.swift
//  Vortex
//
//  Notices when the agent keeps making the same tool call. A call is the tool
//  name plus a hash of its normalized arguments and the state of the page it
//  acts on (address and scroll position), so reading different pages or
//  scrolling further down a long page is not a repeat. Three identical calls in
//  a row add a warning to the result, five in a row are not run, and eight of
//  the same call anywhere in one run stop the run. ask_user and finish are never
//  warned about, blocked or counted.
//

import CryptoKit
import Foundation

struct BrowserAgentToolLoopDetector {
    enum Verdict: Equatable {
        /// Run the call as usual.
        case allow
        /// Run the call, then put a warning in front of its result.
        case warn(repeats: Int)
        /// Do not run the call.
        case block(repeats: Int)
        /// End the run.
        case stop(total: Int)
    }

    static let warningRepeats = 3
    static let blockingRepeats = 5
    static let stoppingTotal = 8
    static let untrackedToolNames: Set<String> = ["ask_user", "finish"]

    private struct Signature: Hashable {
        let name: String
        let digest: String
    }

    private var previous: Signature?
    private var consecutive = 0
    private var totals: [Signature: Int] = [:]

    /// Records one call and says what to do with it. `pageState` describes the page the call acts on, if any.
    mutating func record(name: String, argumentsJSON: String, pageState: String? = nil) -> Verdict {
        guard !Self.untrackedToolNames.contains(name) else {
            // The user's answer can change what the same call returns, so a question ends the streak.
            if name == "ask_user" {
                previous = nil
                consecutive = 0
            }
            return .allow
        }
        let signature = Signature(name: name, digest: Self.digest(argumentsJSON: argumentsJSON, pageState: pageState))
        consecutive = signature == previous ? consecutive + 1 : 1
        previous = signature
        let total = totals[signature, default: 0] + 1
        totals[signature] = total
        if total >= Self.stoppingTotal { return .stop(total: total) }
        if consecutive >= Self.blockingRepeats { return .block(repeats: consecutive) }
        if consecutive >= Self.warningRepeats { return .warn(repeats: consecutive) }
        return .allow
    }

    static func warningText(toolName: String, repeats: Int) -> String {
        "Repeated call: this exact \(toolName) call has now run \(repeats) times in a row. Try a different action, ask the user, or finish.\n\n"
    }

    static func blockedText(toolName: String, repeats: Int) -> String {
        "Blocked: this exact \(toolName) call was repeated \(repeats) times in a row, so it was not run. Choose a different action, ask the user, or finish with what you have."
    }

    static func stoppedMessage(toolName: String) -> String {
        "Stopped because the agent kept repeating the same \(readableName(toolName)) action without making progress."
    }

    static func readableName(_ toolName: String) -> String {
        toolName.replacingOccurrences(of: "_", with: " ")
    }

    // MARK: Signatures

    /// Sorted keys, trimmed strings and no null values, so equivalent JSON hashes the same.
    static func normalizedArguments(_ json: String) -> String {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "{}" }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let normalized = try? JSONSerialization.data(
                  withJSONObject: normalizedValue(object),
                  options: [.sortedKeys, .fragmentsAllowed]
              ) else {
            return trimmed
        }
        return String(decoding: normalized, as: UTF8.self)
    }

    nonisolated private static func normalizedValue(_ value: Any) -> Any {
        switch value {
        case let object as [String: Any]:
            return object.filter { !($0.value is NSNull) }.mapValues(normalizedValue)
        case let array as [Any]:
            return array.map(normalizedValue)
        case let string as String:
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            return value
        }
    }

    private static func digest(argumentsJSON: String, pageState: String?) -> String {
        let material = normalizedArguments(argumentsJSON) + "\n" + (pageState ?? "")
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

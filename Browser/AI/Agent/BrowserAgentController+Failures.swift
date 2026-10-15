//
//  BrowserAgentController+Failures.swift
//  Vortex
//
//  Error types thrown by the browser agent's tools and page scripts.

import Foundation
import WebKit
import Combine
import UIKit

extension BrowserAgentController {
    struct ScriptTimeout: LocalizedError {
        var errorDescription: String? { "The page did not respond in time." }
    }

    struct ScriptFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    enum BrowserToolFailure: LocalizedError {
        case unavailable
        case invalidArgument(String)
        case missingDataset
        case datasetLimit
        case invalidComparison
        case stalePage
        case screenshotMaskRestoreFailed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "These browser tools are unavailable for this starting page; the existing page tools remain available."
            case .invalidArgument(let message): return message
            case .missingDataset: return "That dataset is not available in this agent run. Extract it again or use one of the listed dataset IDs."
            case .datasetLimit: return "The run's bounded dataset storage is full. Export or compare existing datasets first."
            case .invalidComparison: return "The comparison needs existing dataset IDs and bounded row values."
            case .stalePage: return "The page or tab changed while this action was running. Please retry from a fresh snapshot."
            case .screenshotMaskRestoreFailed(let message): return message
            }
        }
    }
}

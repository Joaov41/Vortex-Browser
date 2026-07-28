# AI Sidebar Assistant Message Truncation

Date: 2026-04-17

## Summary

The compact AI sidebar no longer truncates long assistant replies.

This change was made because WebAI responses were being cut off in the UI even when the full response had already been captured successfully.

## Previous Behavior

`AISidebarConversationHistoryView` in `Browser/AI/AISidebar.swift` used to:

- cap assistant messages at `1800` characters
- append `[Response truncated for performance.]`

This was a display-only truncation in the sidebar history view. It was not part of Reddit extraction, model output generation, or WebAI capture.

## Current Behavior

Assistant replies now render their full trimmed text in the sidebar history view.

## Why This May Need To Be Revisited

If very long replies cause UI regressions, the likely symptoms would be:

- slower scrolling in the sidebar
- larger layout/reflow cost for long conversations
- heavier memory usage from rendering large text blocks

## How To Revert

Restore the truncation logic in `Browser/AI/AISidebar.swift` inside `AISidebarConversationHistoryView`.

Reintroduce:

- a `truncateAssistantMessages` flag
- an `olderAssistantTextCap` value
- the old `assistantDisplayText(for:)` truncation branch

The previous cap was `1800` characters, but if truncation is needed again, a higher cap such as `4000` to `8000` may be a better compromise before falling back to the old `1800`.

## Intent

Prefer full-response display unless real rendering or performance problems appear in the sidebar.

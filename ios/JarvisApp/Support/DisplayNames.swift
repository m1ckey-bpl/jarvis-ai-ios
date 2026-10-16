import SwiftUI

/// Human-friendly labels for core enums. Kept in the app layer so JarvisCore
/// stays presentation-free (and testable on Linux).

extension MemoryKind {
    var displayName: String {
        switch self {
        case .fact: return "Fact"
        case .preference: return "Preference"
        case .goal: return "Goal"
        case .importantDate: return "Important date"
        case .decision: return "Decision"
        case .task: return "Task"
        case .instruction: return "Instruction"
        case .inference: return "Inference"
        case .correction: return "Correction"
        case .summary: return "Summary"
        }
    }
}

extension RiskClass {
    var displayName: String {
        switch self {
        case .safe: return "Safe"
        case .modifying: return "Modifying"
        case .communicating: return "Sends a message"
        case .irreversible: return "Irreversible"
        }
    }
}

extension ToolExecutionLog.Entry {
    /// The log stores `success` plus an optional error string; the UI derives a
    /// status from those two facts rather than inventing a third source of truth.
    var statusLabel: String {
        if success { return "succeeded" }
        if let errorMessage, !errorMessage.isEmpty { return "failed" }
        return "unknown"
    }

    var statusColor: Color {
        if success { return JarvisTheme.Palette.mint }
        if let errorMessage, !errorMessage.isEmpty { return JarvisTheme.Palette.rose }
        return JarvisTheme.Palette.amber
    }

    var statusIcon: String {
        if success { return verified ? "checkmark.seal.fill" : "checkmark.circle.fill" }
        return "xmark.octagon.fill"
    }
}

extension MessageRole {
    var displayName: String { rawValue.capitalized }
}

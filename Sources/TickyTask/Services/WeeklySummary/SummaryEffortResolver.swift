import Foundation

/// Reconciles effort choices across Codex models, handling capability mismatches.
enum SummaryEffortResolver {
    static let standardLevels = ["low", "medium", "high", "xhigh", "max"]

    /// The effort choices offered for `model`, in display order. A catalog model
    /// with known levels gets "Model default (X)" — applied explicitly so a global
    /// effort in the user's Codex config can't leak in — plus its levels. The CLI
    /// default model, custom ids, and local models (no capability data) get
    /// "CLI default" plus the standard levels, which are unverified.
    static func choices(model: SummaryModelOption) -> [EffortChoice] {
        guard let supported = model.supportedEfforts, !supported.isEmpty else {
            return [.cliDefault] + standardLevels.map { .level($0) }
        }
        var result: [EffortChoice] = []
        if let defaultLevel = model.defaultEffort, supported.contains(defaultLevel) {
            result.append(.modelDefault(defaultLevel))
        }
        result.append(contentsOf: supported.map { .level($0) })
        return result
    }

    /// Reconcile a remembered effort with the currently offered choices.
    /// Returns the effort to use and an optional note explaining any change.
    static func reconcile(remembered: EffortChoice?,
                          model: SummaryModelOption) -> (choice: EffortChoice, note: String?) {
        let offered = choices(model: model)

        // If no remembered choice, pick the first offered (prefer model default, then CLI default).
        guard let remembered else {
            return (offered.first ?? .cliDefault, nil)
        }

        // Check if the remembered choice is still offered.
        if offered.contains(remembered) {
            return (remembered, nil)
        }

        // Remembered choice is no longer offered; reconcile.
        var fallback: EffortChoice?
        var note: String?

        // Prefer model default if available.
        if case .modelDefault(let level) = remembered {
            // The remembered was a model default but is no longer offered.
            // Check if the new model has a different default.
            if let newDefault = model.defaultEffort, model.supportedEfforts?.contains(newDefault) ?? false {
                fallback = .modelDefault(newDefault)
                let oldLabel = label(for: remembered)
                let newLabel = label(for: .modelDefault(newDefault))
                note = "\(oldLabel) isn't available for \(model.label) — using \(newLabel)."
            }
        }

        // If no fallback yet, try the first offered level or choice.
        if fallback == nil {
            fallback = offered.first ?? .cliDefault
            let fallbackChoice = fallback!
            if case .modelDefault = fallbackChoice, remembered != fallbackChoice {
                let oldLabel = label(for: remembered)
                let newLabel = label(for: fallbackChoice)
                note = "\(oldLabel) isn't available for \(model.label) — using \(newLabel)."
            } else if remembered != fallbackChoice {
                let oldLabel = label(for: remembered)
                let newLabel = label(for: fallbackChoice)
                note = "\(oldLabel) isn't available for \(model.label) — using \(newLabel)."
            }
        }

        return (fallback ?? .cliDefault, note)
    }

    /// Human-readable label for an effort choice.
    static func label(for choice: EffortChoice) -> String {
        switch choice {
        case .cliDefault:
            return "CLI default"
        case .modelDefault(let level):
            return "Model default (\(capitalizeLevel(level)))"
        case .level(let level):
            return capitalizeLevel(level)
        }
    }

    private static func capitalizeLevel(_ level: String) -> String {
        switch level.lowercased() {
        case "low": return "Low"
        case "medium": return "Medium"
        case "high": return "High"
        case "xhigh": return "Extra high"
        case "max": return "Max"
        case "ultra": return "Ultra"
        default: return level.prefix(1).uppercased() + level.dropFirst()
        }
    }
}

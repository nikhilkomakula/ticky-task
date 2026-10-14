import Testing
import Foundation
@testable import TickyTask

@Suite("SummaryEffortResolver")
struct SummaryEffortResolverTests {
    @Test("Codex with known model and supported efforts")
    func codexKnownModel() {
        let model = SummaryModelOption(
            id: "gpt-5.5",
            label: "GPT-5.5",
            source: .catalog,
            supportedEfforts: ["low", "medium", "high", "xhigh"],
            defaultEffort: "medium"
        )
        let choices = SummaryEffortResolver.choices(model: model)

        // Should have modelDefault + the supported levels.
        #expect(choices.contains(.modelDefault("medium")))
        #expect(choices.contains(.level("low")))
        #expect(choices.contains(.level("medium")))
        #expect(choices.contains(.level("high")))
        #expect(choices.contains(.level("xhigh")))
        #expect(!choices.contains(.cliDefault))
    }

    @Test("Codex CLI default model offers CLI default + standard levels")
    func codexCLIDefaultModel() {
        let model = SummaryModelOption.cliDefault
        let choices = SummaryEffortResolver.choices(model: model)

        #expect(choices.contains(.cliDefault))
        #expect(choices.contains(.level("low")))
        #expect(choices.contains(.level("max")))
    }

    @Test("Codex custom model with unknown efforts")
    func codexCustomModelUnknownEfforts() {
        let model = SummaryModelOption(
            id: "my-custom-model",
            label: "Custom Model",
            source: .custom,
            supportedEfforts: nil,
            defaultEffort: nil
        )
        let choices = SummaryEffortResolver.choices(model: model)

        #expect(choices.contains(.cliDefault))
        #expect(choices.contains(.level("low")))
        #expect(choices.contains(.level("max")))
    }

    @Test("reconcile keeps remembered if still offered")
    func reconcileKeepsRemembered() {
        let model = SummaryModelOption(
            id: "model",
            label: "Model",
            source: .catalog,
            supportedEfforts: ["low", "high"],
            defaultEffort: "low"
        )

        let result = SummaryEffortResolver.reconcile(
            remembered: .level("high"),
            model: model
        )
        #expect(result.choice == .level("high"))
        #expect(result.note == nil)
    }

    @Test("reconcile uses first offered when no remembered")
    func reconcileNoneOffersFirst() {
        let model = SummaryModelOption(
            id: "model",
            label: "Model",
            source: .catalog,
            supportedEfforts: ["high", "max"],
            defaultEffort: "high"
        )

        let result = SummaryEffortResolver.reconcile(
            remembered: nil,
            model: model
        )
        // First offered is modelDefault.
        #expect(result.choice == .modelDefault("high"))
        #expect(result.note == nil)
    }

    @Test("reconcile switches and notes when remembered not offered")
    func reconcilesNotOfferedWithNote() {
        let model = SummaryModelOption(
            id: "gpt-5.5",
            label: "GPT-5.5",
            source: .catalog,
            supportedEfforts: ["low", "medium", "high"],
            defaultEffort: "medium"
        )

        let result = SummaryEffortResolver.reconcile(
            remembered: .level("xhigh"),
            model: model
        )
        #expect(result.choice != .level("xhigh"))
        #expect(result.note != nil)
    }

    @Test("reconcile GLM case: remembered modelDefault differs from new default")
    func reconcileGLMDifferentDefault() {
        // GLM supports high/max, default max; remembered was modelDefault(xhigh).
        let model = SummaryModelOption(
            id: "glm-5.2",
            label: "GLM 5.2",
            source: .catalog,
            supportedEfforts: ["high", "max"],
            defaultEffort: "max"
        )

        let result = SummaryEffortResolver.reconcile(
            remembered: .modelDefault("xhigh"),
            model: model
        )
        #expect(result.choice == .modelDefault("max"))
        #expect(result.note != nil)
        let noteContains = result.note?.lowercased() ?? ""
        #expect(noteContains.contains("extra high") || noteContains.contains("model default"))
    }

    @Test("label for cliDefault")
    func labelCLIDefault() {
        let label = SummaryEffortResolver.label(for: .cliDefault)
        #expect(label == "CLI default")
    }

    @Test("label for standard levels")
    func labelStandardLevels() {
        #expect(SummaryEffortResolver.label(for: .level("low")) == "Low")
        #expect(SummaryEffortResolver.label(for: .level("medium")) == "Medium")
        #expect(SummaryEffortResolver.label(for: .level("high")) == "High")
        #expect(SummaryEffortResolver.label(for: .level("xhigh")) == "Extra high")
        #expect(SummaryEffortResolver.label(for: .level("max")) == "Max")
        #expect(SummaryEffortResolver.label(for: .level("ultra")) == "Ultra")
    }

    @Test("label for modelDefault")
    func labelModelDefault() {
        let label = SummaryEffortResolver.label(for: .modelDefault("medium"))
        #expect(label == "Model default (Medium)")
    }

    @Test("label for unknown level")
    func labelUnknown() {
        let label = SummaryEffortResolver.label(for: .level("unknownlevel"))
        #expect(label == "Unknownlevel")
    }
}

import HoloCore
import SwiftUI

struct EvaluationView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if model.selectedProfile == nil {
                ContentUnavailableView {
                    Label("No Desk Profile", systemImage: "checkmark.seal")
                } description: {
                    Text("Calibrate the four desk zones before evaluating them.")
                } actions: {
                    Button("Open Calibration") { model.section = .calibrate }
                        .holoPrimaryButton()
                }
            } else if let session = model.evaluationSession {
                activeSession(session)
            } else if let report = model.latestEvaluation {
                reportView(report)
            } else {
                intro
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HoloTheme.background)
    }

    private var intro: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "checkmark.seal")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            VStack(spacing: 7) {
                Text("Test your calibration")
                    .font(.title.weight(.semibold))
                Text("Use new taps that were not part of calibration. Holo guides \(EvaluationAcceptance.tapsPerZone) taps in each zone and counts rejected taps as incorrect.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }

            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 10) {
                acceptanceRow(
                    "Taps",
                    "\(DeskZone.allCases.count * EvaluationAcceptance.tapsPerZone) total · \(EvaluationAcceptance.tapsPerZone) per zone"
                )
                acceptanceRow(
                    "Accuracy target",
                    "\(Int(EvaluationAcceptance.minimumAccuracy * 100))% or better"
                )
                acceptanceRow(
                    "Response target",
                    "Median under \(Int(EvaluationAcceptance.maximumMedianResponseMilliseconds)) ms"
                )
                acceptanceRow("Output", "Per-zone accuracy and confusion matrix")
            }
            .font(.callout)

            Button("Start Accuracy Test") { model.beginEvaluation() }
                .holoPrimaryButton()
                .controlSize(.large)
            Spacer()
        }
        .padding(36)
    }

    private func activeSession(_ session: EvaluationSession) -> some View {
        ScrollView {
            VStack(spacing: 22) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.currentZone?.displayName ?? "Complete")
                            .font(.title.weight(.semibold))
                        Text("Tap the highlighted zone naturally.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(session.records.count) of \(DeskZone.allCases.count * session.targetPerZone)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                ProgressView(value: session.progress)
                    .accessibilityLabel("Evaluation progress")
                    .accessibilityValue(
                        "\(session.records.count) of \(DeskZone.allCases.count * session.targetPerZone) taps completed"
                    )

                DeskMapView(
                    activeZone: model.activeZone,
                    targetZone: session.currentZone,
                    confidence: model.lastDecision?.confidence ?? 0,
                    signalStrength: model.lastDecision?.signalStrength ?? 0,
                    isListening: model.audio.isListening,
                    counts: DeskZone.allCases.map { zone in
                        session.records.filter { $0.expectedZone == zone }.count
                    }
                )
                .frame(maxWidth: 760)

                VStack(spacing: 14) {
                    if session.isSettling {
                        HStack(spacing: 9) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Preparing the microphone…")
                                .font(.headline)
                        }
                        .accessibilityElement(children: .combine)
                    } else if session.isArmed {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(.red)
                                .frame(width: 7, height: 7)
                            Text("Accuracy test armed")
                                .font(.headline)
                            if let zone = session.currentZone {
                                let count = session.records.filter { $0.expectedZone == zone }.count
                                Text("Tap \(count + 1) of \(session.targetPerZone)")
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    } else if let zone = session.currentZone {
                        Text("Move to \(zone.displayName.lowercased()). Sounds are ignored until you arm this zone.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Arm \(zone.displayName)") { model.armEvaluationZone() }
                            .holoPrimaryButton()
                            .controlSize(.large)
                            .disabled(!model.audio.isListening)
                            .help(model.audio.isListening ? "Start testing this zone" : "Resume the microphone before arming")
                            .accessibilityHint(model.audio.isListening
                                ? "Starts listening for evaluation taps in this zone."
                                : "The microphone is paused. Resume it before arming.")
                    }

                    HStack(spacing: 20) {
                        let accuracy = session.records.isEmpty
                            ? 0
                            : Double(session.records.filter(\.isCorrect).count) / Double(session.records.count)
                        LabeledContent("Accuracy so far", value: "\(Int(accuracy * 100))%")
                        if let decision = model.lastDecision {
                            LabeledContent("Last result", value: decision.zone?.displayName ?? "Rejected")
                        }
                        Spacer()
                        Button("Cancel", role: .cancel) { model.cancelEvaluation() }
                    }
                    .font(.callout)
                }
                .padding(16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .frame(maxWidth: 820)
            .padding(32)
            .frame(maxWidth: .infinity)
        }
    }

    private func reportView(_ report: EvaluationReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(report.meetsAccuracyAndLatencyTargets ? "Accuracy test passed" : "Accuracy test complete")
                            .font(.title.weight(.semibold))
                        Text("\(report.profileName) · \(report.strategy.displayName)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text(report.completedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button("Run Again") { model.beginEvaluation() }
                        .holoSecondaryButton()
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Summary")
                        .font(.headline)
                    Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 9) {
                        summaryRow(
                            "Overall accuracy",
                            "\(Int(report.overallAccuracy * 100))% · \(report.meetsAccuracyTarget ? "Meets 80% target" : "Below 80% target")"
                        )
                        summaryRow(
                            "Median response",
                            latencySummary(report)
                        )
                        summaryRow(
                            "Balanced session",
                            report.isBalancedAcceptanceSession
                                ? "\(DeskZone.allCases.count) × \(EvaluationAcceptance.tapsPerZone)"
                                : "No"
                        )
                        summaryRow("Rejected taps", "\(report.records.filter { $0.predictedZone == nil }.count)")
                    }
                    .font(.callout)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Per-zone accuracy")
                        .font(.headline)
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 9) {
                        GridRow {
                            Text("Zone").foregroundStyle(.secondary)
                            Text("Correct").foregroundStyle(.secondary)
                            Text("Accuracy").foregroundStyle(.secondary)
                        }
                        ForEach(report.perZoneAccuracy) { item in
                            GridRow {
                                Text(item.zone.displayName)
                                Text("\(item.correct) / \(item.total)").monospacedDigit()
                                HStack {
                                    ProgressView(value: item.accuracy)
                                        .frame(width: 150)
                                    Text("\(Int(item.accuracy * 100))%")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(item.zone.displayName)
                            .accessibilityValue(
                                "\(item.correct) of \(item.total) correct, \(Int(item.accuracy * 100)) percent"
                            )
                        }
                    }
                    .font(.callout)
                }

                confusionMatrix(report)

                if model.latestEvaluationIsPersisted {
                    Text("JSON and CSV reports are saved locally in Holo's Application Support folder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label(
                        "This result is in memory only because its JSON and CSV files were not saved.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(36)
            .frame(maxWidth: .infinity)
        }
    }

    private func confusionMatrix(_ report: EvaluationReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Confusion matrix")
                .font(.headline)
            Text("Rows are expected zones. Columns are predicted zones; R is rejected.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Grid(horizontalSpacing: 5, verticalSpacing: 5) {
                GridRow {
                    Text("")
                    ForEach(DeskZone.allCases) { zone in matrixLabel(zone.shortName) }
                    matrixLabel("R")
                }
                ForEach(DeskZone.allCases) { expected in
                    GridRow {
                        matrixLabel(expected.shortName)
                        ForEach(DeskZone.allCases) { predicted in
                            matrixCell(
                                report.confusionMatrix[expected.rawValue][predicted.rawValue],
                                diagonal: expected == predicted
                            )
                        }
                        matrixCell(report.rejectedPerZone[expected.rawValue], diagonal: false)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Confusion matrix")
            .accessibilityValue(confusionMatrixAccessibilityValue(report))
        }
    }

    private func confusionMatrixAccessibilityValue(_ report: EvaluationReport) -> String {
        DeskZone.allCases.map { expected in
            let predictions = DeskZone.allCases.map { predicted in
                "\(predicted.displayName) \(report.confusionMatrix[expected.rawValue][predicted.rawValue])"
            }
            let rejected = report.rejectedPerZone[expected.rawValue]
            return "Expected \(expected.displayName): \(predictions.joined(separator: ", ")), rejected \(rejected)."
        }
        .joined(separator: " ")
    }

    private func acceptanceRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .monospacedDigit()
        }
    }

    private func latencySummary(_ report: EvaluationReport) -> String {
        guard report.hasCompleteResponseLatency else {
            return "Unavailable · one or more timestamps were invalid"
        }
        return String(
            format: "%.0f ms · %@",
            report.medianResponseLatencyMilliseconds,
            report.meetsLatencyTarget ? "Under 200 ms target" : "At or above 200 ms target"
        )
    }

    private func matrixLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2.monospaced().weight(.medium))
            .foregroundStyle(.secondary)
            .frame(width: 34, height: 22)
    }

    private func matrixCell(_ value: Int, diagonal: Bool) -> some View {
        Text("\(value)")
            .font(.caption.monospacedDigit())
            .frame(width: 34, height: 28)
            .background(
                (diagonal ? Color.green : Color.orange)
                    .opacity(value == 0 ? 0.04 : min(0.10 + Double(value) * 0.055, 0.48)),
                in: RoundedRectangle(cornerRadius: 5)
            )
    }
}

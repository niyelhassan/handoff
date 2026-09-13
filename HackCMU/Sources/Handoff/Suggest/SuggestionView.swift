import SwiftUI

/// The suggestion, already made.
///
/// The window opens with Handoff's guess filled in - what the task is, what its
/// steps are, which step changes each pass - and the only thing missing is an
/// answer. It never asks the user to describe anything: a person who has to
/// explain their own repetitive task has been handed more work, not less.
struct SuggestionView: View {

    @Bindable var controller: SuggestionController
    /// Focused when the confirmation opens, so the name can be corrected
    /// without hunting for the field first.
    @FocusState private var nameFocused: Bool

    var body: some View {
        if let summary = controller.summary, let candidate = controller.live {
            card(summary, candidate)
        } else {
            // Between `finish()` clearing state and the fade-out completing.
            Color.clear.frame(width: 360, height: 1)
        }
    }

    private func card(_ s: PatternSummary, _ c: LoopCandidate) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            switch controller.stage {
            case .suggesting:
                content(s, c)
                footer
            case .confirming:
                confirmation(c)
                confirmFooter
            case .rejecting:
                rejection
                rejectFooter
            case .running, .done, .failed:
                runState
            }
        }
        .frame(width: 360)
        .background(.regularMaterial, in: shape)
        .overlay(shape.strokeBorder(.primary.opacity(0.10), lineWidth: 1))
        .clipShape(shape)
    }

    // MARK: - Stage 2: what "the rest" actually means

    /// Deliberately a separate screen. Answering "yes, this is my task" and
    /// authorising Handoff to drive 28 more passes are different decisions, and
    /// collapsing them into one button means the second one never gets made.
    @ViewBuilder
    private func confirmation(_ c: LoopCandidate) -> some View {
        let plan = controller.plan
        VStack(alignment: .leading, spacing: 10) {
            // The name is Handoff's guess and the user's to correct. It is what
            // gets remembered, so it has to be theirs.
            VStack(alignment: .leading, spacing: 3) {
                Text("Call it").font(.caption2).foregroundStyle(.tertiary)
                TextField("Name this task", text: $controller.editedName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .focused($nameFocused)
                    // Delayed on purpose: onAppear fires while the window is
                    // still being made key, and a focus request from that
                    // moment is dropped on the floor.
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            nameFocused = true
                        }
                    }
            }

            runCountRow(plan)

            if let step = plan?.commitStep, let label = plan?.commitLabel {
                Toggle(isOn: Binding(get: { controller.stopBeforeCommit },
                                     set: { controller.setStopBeforeCommit($0) })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Stop before step \(step + 1) (\(label))")
                            .font(.system(size: 11, weight: .medium))
                        Text("Handoff does the work and hands it back for you to send.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // What it would do to the NEXT instance, resolved against what is
            // on screen now - before anything is touched.
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text("Next pass, step by step")
                        .font(.caption2).foregroundStyle(.tertiary)
                    if controller.previewing {
                        ProgressView().controlSize(.mini).scaleEffect(0.6)
                    }
                }
                if controller.preview.isEmpty && !controller.previewing {
                    Text("Handoff could not resolve the next pass - the window it "
                         + "needs may not be open.")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // The stop is a SETTING, not a step, so it is rendered from
                // the setting rather than parroted back from the engine's log -
                // which keeps it honest the instant the checkbox changes.
                ForEach(Array(controller.preview.filter {
                    !$0.contains("stopping before")
                }.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if controller.stopBeforeCommit, let step = plan?.commitStep,
                   let label = plan?.commitLabel, !controller.preview.isEmpty {
                    Text("⏸ then stops, leaving step \(step + 1) (\(label)) to you")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let blockers = plan?.blockers, !blockers.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(blockers.enumerated()), id: \.offset) { _, b in
                        Label {
                            Text(b).font(.system(size: 11))
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9))
                        }
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }

            Label("Press any key or click to stop it at any point.",
                  systemImage: "hand.raised")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
    }

    @ViewBuilder
    private func runCountRow(_ plan: LoopPlan?) -> some View {
        if controller.stopBeforeCommit, plan?.commitStep != nil {
            Label("One at a time, because this task ends in something you cannot "
                  + "take back.", systemImage: "1.circle")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(spacing: 6) {
                Text("Run it").font(.system(size: 12))
                TextField("", value: $controller.runCount,
                          format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 48)
                    .font(.system(size: 12))
                Stepper("", value: $controller.runCount,
                        in: 1...controller.maxRuns)
                    .labelsHidden()
                Text(controller.runCount == 1 ? "more time" : "more times")
                    .font(.system(size: 12))
                Spacer()
                if case .known(let remaining, _, _)? = plan?.bound {
                    Text("\(remaining) left")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var confirmFooter: some View {
        HStack(spacing: 8) {
            Button("Back") { controller.backToSuggestion() }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.tertiary)
            Spacer()
            Button("Cancel") { controller.notNow() }
                .buttonStyle(SoftButtonStyle(prominent: false))
            Button(runLabel) { controller.confirmRun() }
                .buttonStyle(SoftButtonStyle(prominent: controller.plan?.isReplayable == true))
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 14)
    }

    private var runLabel: String {
        let n = controller.effectiveRuns
        if controller.plan?.isReplayable != true { return "Run anyway" }
        return n == 1 ? "Run once" : "Run \(n) times"
    }

    // MARK: - Rejection

    /// A wrong guess is information. Recording why keeps Handoff from making the
    /// same one, and is the only way the user can push back on the detector.
    private var rejection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What did Handoff get wrong?")
                .font(.system(size: 14, weight: .semibold))
            Text("These steps won't be suggested again.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("e.g. these are different courses, not the same task",
                      text: $controller.rejectReason, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .lineLimit(2...4)
        }
        .padding(.horizontal, 14)
    }

    private var rejectFooter: some View {
        HStack(spacing: 8) {
            Button("Back") { controller.backToSuggestion() }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.tertiary)
            Spacer()
            Button("Don't suggest this again") { controller.confirmReject() }
                .buttonStyle(SoftButtonStyle(prominent: true))
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 14)
    }

    // MARK: - Stage 3: running

    @ViewBuilder
    private var runState: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch controller.stage {
            case .running:
                Label("Running - press any key to stop", systemImage: "play.circle")
                    .font(.system(size: 13, weight: .medium))
                ProgressView().progressViewStyle(.linear)
            case .done:
                Label("Done", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.green)
            case .failed(let why):
                Label("Stopped", systemImage: "exclamationmark.octagon.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.orange)
                Text(why).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            default:
                EmptyView()
            }
        }
        .padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "repeat")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor))
            Text("Handoff spotted a pattern")
                .font(.caption).fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                controller.notNow()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss for now")
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    // MARK: - Body

    private func content(_ s: PatternSummary, _ c: LoopCandidate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(controller.understanding?.name ?? s.headline)
                    .font(.system(size: 15, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                // Whether a sentence came from a model or from counting is
                // something the reader is entitled to know.
                if controller.understanding?.isFromModel == true {
                    Image(systemName: "sparkles")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .help("Named by Claude")
                }
            }

            // The proposed automation, as a name. This is the "suggestion
            // waiting" - it is what gets saved if the answer is yes.
            Text(s.title)
                .font(.system(size: 11, design: .rounded))
                .fontWeight(.medium)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .fixedSize(horizontal: false, vertical: true)

            evidence(s, c)

            if let notice = controller.recognisedNotice
                ?? controller.recognised.map({ "You've done this before - \($0.timesSeen)× so far" }) {
                Label(notice, systemImage: "clock.arrow.circlepath")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().padding(.vertical, 1)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(s.steps) { step(_: $0) }
            }

            if let note = s.parameterNote {
                Label(note, systemImage: "arrow.triangle.branch")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let concern = controller.understanding?.concern {
                Label(concern, systemImage: "exclamationmark.bubble")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
    }

    private func evidence(_ s: PatternSummary, _ c: LoopCandidate) -> some View {
        HStack(spacing: 8) {
            Text(s.evidence)
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            // Confidence is shown rather than hidden because the user is being
            // asked to sanity-check a guess, and how sure Handoff is bears on it.
            Capsule().fill(.quaternary)
                .frame(width: 42, height: 3)
                .overlay(alignment: .leading) {
                    Capsule().fill(Color.accentColor)
                        .frame(width: 42 * s.confidence, height: 3)
                }
            Text("\(Int(s.confidence * 100))%")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    private func step(_ s: PatternSummary.Step) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(s.id + 1)")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .background(Circle().fill(.quaternary))

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(s.text).font(.system(size: 12))
                    if s.varies {
                        Text("varies")
                            .font(.system(size: 8, weight: .semibold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.orange.opacity(0.18), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
                // Typed content, shown on the user's own screen only. Confirming
                // an automation you cannot see is not consent.
                if let d = s.detail {
                    Text("\u{201C}\(d)\u{201D}")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Not a task") { controller.beginReject() }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .help("Tell Handoff this isn't a real repeated task")
            Spacer()
            Button("Not now") { controller.notNow() }
                .buttonStyle(SoftButtonStyle(prominent: false))
            // Reads as a next step, not a launch: the count and the caveats
            // are on the screen after this one.
            Button("Automate the rest…") { controller.accept() }
                .buttonStyle(SoftButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 14)
    }
}

/// AppKit draws `.borderedProminent` in its inactive grey whenever the window
/// is not key - and this panel is deliberately never key unless the user clicks
/// it, so the primary action would look disabled every single time it appeared.
/// An explicit fill does not depend on key state.
private struct SoftButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(fill(configuration.isPressed),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
    }

    private func fill(_ pressed: Bool) -> AnyShapeStyle {
        prominent
            ? AnyShapeStyle(Color.accentColor.opacity(pressed ? 0.75 : 1))
            : AnyShapeStyle(Color.primary.opacity(pressed ? 0.18 : 0.09))
    }
}

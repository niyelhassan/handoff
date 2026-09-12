import AppKit
import ScoutCore
import SwiftUI

/// The popover that appears beside the user's work when Handoff has spotted a repeated task.
/// It is shown with `orderFrontRegardless()` so it never steals focus from the app the person is in,
/// floats above other windows, joins every Space, and slides in from the right edge of the screen.
/// (Approach adapted from the AA2026/handoff suggestion panel.)
@MainActor final class SuggestionPanel: NSPanel {
    private static var current: SuggestionPanel?
    private let margin: CGFloat = 16

    static func present(model: AppModel) {
        current?.orderOut(nil); current?.close()
        let panel = SuggestionPanel(rootView:SuggestionCard(model:model))
        current = panel
        panel.slideIn()
    }
    static func dismiss() {
        guard let panel = current else { return }
        current = nil
        NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.18; panel.animator().alphaValue = 0; panel.animator().setFrame(panel.frame.offsetBy(dx:40,dy:0),display:true) }) {
            Task { @MainActor in panel.orderOut(nil); panel.contentView = nil; panel.close() }
        }
    }

    private init<Content: View>(rootView: Content) {
        super.init(contentRect:NSRect(x:0,y:0,width:380,height:200),styleMask:[.titled,.fullSizeContentView],backing:.buffered,defer:false)
        titlebarAppearsTransparent = true; titleVisibility = .hidden
        for button in [NSWindow.ButtonType.closeButton,.miniaturizeButton,.zoomButton] { standardWindowButton(button)?.isHidden = true }
        isFloatingPanel = true; level = .floating; hidesOnDeactivate = false; isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.ignoresCycle]
        isMovableByWindowBackground = false; isOpaque = false; backgroundColor = .clear; hasShadow = true
        let host = FirstMouseHostingView(rootView:rootView)
        let controller = NSViewController(); controller.view = host
        contentViewController = controller
        setContentSize(host.fittingSize)
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private func slideIn() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse,$0.frame,false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let size = contentView.map { NSSize(width:max($0.fittingSize.width,360),height:$0.fittingSize.height) } ?? frame.size
        setContentSize(size)
        let target = NSRect(x:visible.maxX - size.width - margin,y:visible.maxY - size.height - margin,width:size.width,height:size.height)
        setFrame(target.offsetBy(dx:size.width + margin,dy:0),display:false)
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.32; ctx.timingFunction = CAMediaTimingFunction(name:.easeOut)
            animator().alphaValue = 1; animator().setFrame(target,display:true)
        }
        NSSound(named:"Glass")?.play()
    }
    /// The card grows as it moves through its stages; keep it pinned to the top-right corner.
    func refit() {
        guard let host = contentView else { return }
        host.layoutSubtreeIfNeeded()
        let fitted = host.fittingSize
        guard fitted.height > 0, abs(fitted.height - frame.height) > 0.5 else { return }
        setFrame(NSRect(x:frame.maxX - fitted.width,y:frame.maxY - fitted.height,width:fitted.width,height:fitted.height),display:true,animate:true)
    }
}

/// Without this the first click only makes the panel key and the button under the pointer never fires.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
    required init(rootView: Content) { super.init(rootView:rootView) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }
}

/// Suggest → build (Grok) → ready → running → done, all inside the card.
struct SuggestionCard: View {
    @ObservedObject var model: AppModel
    @State private var accepted = false
    @State private var started: Automation?

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius:16,style:.continuous) }
    private var run: RunRecord? { started.flatMap { s in model.currentRun?.automation.id == s.id ? model.currentRun : model.activity.first { $0.automation.id == s.id } } }

    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            HStack(spacing:8) {
                Image(systemName:"sparkles").foregroundStyle(.orange)
                Text(headline).font(.system(size:12,weight:.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { finish(false) } label: { Image(systemName:"xmark").font(.system(size:10,weight:.bold)) }.buttonStyle(.plain).foregroundStyle(.tertiary)
            }
            if let judgment = model.judgment {
                Text(judgment.name).font(.system(size:15,weight:.semibold))
                if !accepted { Text(offer ?? judgment.description).font(.system(size:12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true) }
            }
            stage
        }
        .padding(16)
        .frame(width:380)
        .background(.regularMaterial,in:shape)
        .overlay(shape.strokeBorder(.primary.opacity(0.1),lineWidth:1))
        .clipShape(shape)
        .onChange(of:model.review?.id) { _,_ in refit() }
        .onChange(of:model.busy) { _,_ in refit() }
        .onChange(of:run?.status) { _,_ in refit() }
    }

    /// Shape-specific wording for the first stage; falls back to Grok's description.
    private var offer: String? {
        switch model.candidate?.shape {
        case "folders": return "Notice you’re creating folders from this list—want me to generate the rest?"
        default: return nil
        }
    }
    private var headline: String {
        if let run { return run.status == "succeeded" ? "Done" : run.status == "failed" ? "Stopped" : "Handoff is doing it" }
        if accepted { return model.busy ? "Grok is building it…" : "Ready to hand off" }
        return "You’ve done this \(model.candidate?.count ?? 3) times"
    }

    @ViewBuilder private var stage: some View {
        if let run {
            if run.status == "succeeded" {
                Text(summary(run)).font(.system(size:12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                HStack { Spacer(); Button("Show result") { reveal(run) }.controlSize(.small); Button("Close") { finish(true) }.controlSize(.small).keyboardShortcut(.defaultAction) }
            } else if run.status == "failed" {
                Text(run.message).font(.system(size:12)).foregroundStyle(.orange).fixedSize(horizontal:false,vertical:true)
                HStack { Spacer(); Button("Open Handoff") { model.show("activity"); finish(true) }.controlSize(.small) }
            } else {
                HStack(spacing:8) { ProgressView().controlSize(.small); Text(run.completed.last ?? "Starting…").font(.system(size:12)).foregroundStyle(.secondary).lineLimit(1) }
            }
        } else if accepted {
            if model.busy || model.review == nil {
                HStack(spacing:8) { ProgressView().controlSize(.small); Text(model.error.isEmpty ? "Turning your three passes into a routine…" : model.error).font(.system(size:12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true) }
            } else if let plan = model.review {
                VStack(alignment:.leading,spacing:3) {
                    ForEach(Array(plan.steps.filter { ![.endLoop,.endIf].contains($0.operation) }.prefix(6).enumerated()),id:\.offset) { i,step in
                        Text("\(i+1). \(step.title)").font(.system(size:11,design:.monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                HStack { Button("Not now") { finish(false) }.controlSize(.small); Spacer(); Button("Do the rest") { started = plan; model.save(plan); model.run(plan) }.controlSize(.small).keyboardShortcut(.defaultAction) }
            }
        } else {
            HStack {
                Button("Not now") { finish(false) }.controlSize(.small)
                Spacer()
                Button(model.candidate?.shape == "folders" ? "Generate the rest" : "Take it from here") { accepted = true; model.build() }.controlSize(.small).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func summary(_ run: RunRecord) -> String {
        let rows = run.tables.values.map(\.rows.count).max() ?? 0
        if rows > 0 { return "Finished all \(rows) rows, the same way you did the first three." }
        return "Finished, the same way you did it."
    }
    private func reveal(_ run: RunRecord) {
        let written = run.undo.compactMap { $0.afterHash != nil ? $0.path : nil }.last ?? run.values["file"] ?? ""
        if !written.isEmpty { NSWorkspace.shared.selectFile(written,inFileViewerRootedAtPath:"") }
        finish(true)
    }
    private func finish(_ done: Bool) {
        if !done && !accepted { model.suppress(forever:false) }
        if done { model.candidate = nil; model.judgment = nil }
        SuggestionPanel.dismiss()
    }
    private func refit() { DispatchQueue.main.async { (NSApp.windows.first { $0 is SuggestionPanel } as? SuggestionPanel)?.refit() } }
}

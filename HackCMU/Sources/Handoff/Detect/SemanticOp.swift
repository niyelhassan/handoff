import CoreGraphics
import Foundation

/// What a keystroke MEANS, as opposed to which key it was.
///
/// ⌘C is not "key 8 with the command bit": it is Copy, and Copy followed later
/// by Paste is data moving from one place to another - which is the single
/// most automatable thing a person does. Naming the operation is what lets the
/// value scoring see that, the summary say it, and the model be told it
/// without being told what was copied.
enum SemanticOp: String, Sendable, Codable {
    case copy, paste, cut, selectAll
    case save, undo, redo
    case newItem, newTab, close, quit
    case find, open, reload, print
    case send            // ⌘↩ - Mail, Slack, Messages, most web forms
    case trash           // ⌘⌫
    case switchApp       // ⌘⇥
    case switchWindow    // ⌘`
    case nextField       // ⇥
    case confirm         // ↩ on its own
    case dismiss         // ⎋

    /// Reads as a step: "Copy", "Switch app", "Send".
    var label: String {
        switch self {
        case .copy:         return "Copy"
        case .paste:        return "Paste"
        case .cut:          return "Cut"
        case .selectAll:    return "Select all"
        case .save:         return "Save"
        case .undo:         return "Undo"
        case .redo:         return "Redo"
        case .newItem:      return "New"
        case .newTab:       return "New tab"
        case .close:        return "Close"
        case .quit:         return "Quit"
        case .find:         return "Find"
        case .open:         return "Open"
        case .reload:       return "Reload"
        case .print:        return "Print"
        case .send:         return "Send"
        case .trash:        return "Move to Trash"
        case .switchApp:    return "Switch app"
        case .switchWindow: return "Switch window"
        case .nextField:    return "Next field"
        case .confirm:      return "Confirm"
        case .dismiss:      return "Dismiss"
        }
    }

    /// Moves data between places. The heart of what is worth automating.
    var movesData: Bool { self == .copy || self == .paste || self == .cut }

    /// Commits something a person might not want done 27 times on a guess.
    var isCommit: Bool {
        self == .send || self == .save || self == .trash || self == .print
    }

    /// The keystroke is a means to an app switch, which the stream records
    /// separately when the frontmost process changes. Counting both would
    /// make every ⌘⇥ a two-step task.
    var isSubsumedBySwitch: Bool { self == .switchApp || self == .switchWindow }

    // MARK: - Classification

    private static let cmd = CGEventFlags.maskCommand.rawValue
    private static let shift = CGEventFlags.maskShift.rawValue
    private static let ctrl = CGEventFlags.maskControl.rawValue
    private static let opt = CGEventFlags.maskAlternate.rawValue

    /// Virtual keycodes are layout-independent for the ANSI letter keys, which
    /// is why this keys on them rather than on the typed character.
    static func classify(keyCode: UInt16, modifiers: UInt64) -> SemanticOp? {
        let hasCmd = modifiers & cmd != 0
        let hasShift = modifiers & shift != 0
        let hasCtrl = modifiers & ctrl != 0
        let hasOpt = modifiers & opt != 0

        if hasCmd, !hasCtrl {
            switch (keyCode, hasShift, hasOpt) {
            case (8, false, false):  return .copy        // C
            case (9, _, false):      return .paste       // V, ⇧⌘V paste-and-match
            case (7, false, false):  return .cut         // X
            case (0, false, false):  return .selectAll   // A
            case (1, _, false):      return .save        // S, ⇧⌘S
            case (6, false, false):  return .undo        // Z
            case (6, true, false):   return .redo        // ⇧⌘Z
            case (45, _, false):     return .newItem     // N
            case (17, false, false): return .newTab      // T
            case (13, _, false):     return .close       // W
            case (12, false, false): return .quit        // Q
            case (3, false, false):  return .find        // F
            case (31, false, false): return .open        // O
            case (15, false, false): return .reload      // R
            case (35, false, false): return .print       // P
            case (0x24, _, _):       return .send        // ⌘↩
            case (0x33, false, false): return .trash     // ⌘⌫
            case (0x30, _, false):   return .switchApp   // ⌘⇥
            case (0x32, _, false):   return .switchWindow // ⌘`
            default:                 return nil
            }
        }
        if !hasCmd, !hasCtrl, !hasOpt {
            switch keyCode {
            case 0x30: return .nextField    // ⇥
            case 0x24: return .confirm      // ↩
            case 0x35: return .dismiss      // ⎋
            default:   return nil
            }
        }
        return nil
    }
}

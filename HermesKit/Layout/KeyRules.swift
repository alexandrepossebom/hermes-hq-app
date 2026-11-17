// [m9/ipad] The hardware keyboard's rules as pure functions (docs/spec/3x-ipad.md §4.10), unit tested in Tests/IPad.

import Foundation

/// What Escape does: the first match wins (web `use-composer-esc-cancel.ts`: Escape closes the layer on top and never
/// doubles as stopping the reply behind it; it never answers a waiting question).
nonisolated enum EscapeAction: Equatable, Sendable {
    case system            // a menu or an alert is up: the system closes it
    case dismissPresented  // a sheet, popover or full-screen viewer
    /// [keys] The model panel (the message bar's model bubble, ⋯ › Model) is open over the chat: it closes, ahead of
    /// Stop (Mac polish #13).
    case closeModelPanel
    case closeFind
    /// [composer-drawers] The slash or @ drawer is open: it closes, the text stays (docs/spec/3x-composer.md §3.2).
    case closeDrawer
    case cancelRecording
    case cancelSearch
    case nothing
    /// [mac] The bot's question card takes Escape as its Skip (Mac audit #26, owner 2026-11-02; Mac polish #7). Skip
    /// answers the question, asking first when answers would be lost, so a parked turn is still never cancelled.
    case skipQuestion
    case stop
    case resignField

    struct State: Equatable, Sendable {
        var alert = false, presented = false, find = false, recording = false, searching = false
        var question = false, running = false, fieldFocused = false
        var drawer = false
        /// [keys] The model panel is open (Mac polish #13).
        var modelPanel = false
        /// [mac] The question waiting is a question card that takes Escape as Skip (an approval card takes nothing).
        var questionSkips = false
    }

    static func decide(_ state: State) -> EscapeAction {
        if state.alert { return .system }
        if state.presented { return .dismissPresented }
        if state.modelPanel { return .closeModelPanel }
        if state.find { return .closeFind }
        if state.drawer { return .closeDrawer }
        if state.recording { return .cancelRecording }
        if state.searching { return .cancelSearch }
        if state.question { return state.questionSkips ? .skipQuestion : .nothing }
        if state.running { return .stop }
        if state.fieldFocused { return .resignField }
        return .nothing
    }
}

/// A hardware keyboard's Return in the message field (web FE-037): Return sends, Shift- or Option-Return adds a line,
/// Return while an input method is composing confirms the composition. The on-screen keyboard's Return adds a line.
nonisolated enum ReturnKey: Equatable, Sendable {
    case send, newline, swallow, pass

    static func decide(hardware: Bool, shift: Bool, option: Bool, marked: Bool, empty: Bool) -> ReturnKey {
        guard hardware, !marked else { return .pass }
        if shift || option { return .newline }
        return empty ? .swallow : .send
    }
}

/// [m9/composer] A hardware Return in an EMPTY message field (web `composer/index.tsx:1014-1037`, docs/spec/3x-composer.md
/// §1.2): with messages waiting it sends the next one (idle) or runs Send Now on the head row (a reply is running).
/// A paused queue never drains from the keyboard: it needs Resume.
nonisolated enum EmptyReturn: Equatable, Sendable {
    case nothing, sendNext, sendNowHead

    /// `waiting`: visible queue rows. `paused`: the queue is parked. `canAct`: the composer's circle is Send, Stop or
    /// idle (never Talk in progress or Stop Dictation).
    static func decide(running: Bool, waiting: Int, paused: Bool, canAct: Bool) -> EmptyReturn {
        guard canAct, waiting > 0, !paused else { return .nothing }
        return running ? .sendNowHead : .sendNext
    }
}

/// Next / Previous Chat: the row after or before the chat on show in the list's current order. No wrap.
nonisolated enum ChatWalk {
    /// `order`: the visible rows' keys, top to bottom (hidden rows and collapsed sections already left out).
    static func target(order: [String], current: String?, forward: Bool) -> String? {
        guard !order.isEmpty else { return nil }
        guard let current, let index = order.firstIndex(of: current) else { return forward ? order.first : nil }
        let next = index + (forward ? 1 : -1)
        return order.indices.contains(next) ? order[next] : nil
    }
}

/// [Mac AAA 2026-11-17] Owner's call Q1 (as Messages): a key typed while a chat is open and nothing has the keyboard
/// goes into that chat's message box. Which key presses are typing, from the AppKit key-down: a printable key with no
/// ⌘ or ⌃ (Shift and Option are typing: ⌥E starts an accent), never a key the window already uses with nothing
/// focused (Return, Enter, Tab, Space, Delete, Escape, the arrows, Page Up/Down, Home, End, the function keys). ⌃⌘Space
/// (Emoji & Symbols) counts too, so the picker opens on the box. Key codes are the Mac's virtual key codes.
nonisolated enum TypeToChat {
    /// Return, Tab, Space, Delete, Escape, Clear, Enter, Help, Home, Page Up, Forward Delete, End, Page Down, the arrows.
    static let windowKeys: Set<UInt16> = [36, 48, 49, 51, 53, 71, 76, 114, 115, 116, 117, 119, 121, 123, 124, 125, 126]
    /// F1 to F20.
    static let functionKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]

    /// `characters`: the key's characters with no modifier applied (AppKit's `charactersIgnoringModifiers`).
    static func takes(keyCode: UInt16, characters: String?, command: Bool, control: Bool) -> Bool {
        if command && control { return keyCode == 49 }   // ⌃⌘Space: Emoji & Symbols
        guard !command, !control, !windowKeys.contains(keyCode), !functionKeys.contains(keyCode),
              let scalar = characters?.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0..<0x20, 0x7F, 0xF700...0xF8FF: return false   // control characters, AppKit's function-key range
        default: return scalar != " "
        }
    }
}

/// ⌘1…⌘9, View's tab items: which place each number picks (`KeyCommands.tabIndex`).
nonisolated enum TabShortcut {
    /// The place ⌘(`index` + 1) picks, as an index into the places with these tab tags, for `keys` numbers: the numbers
    /// go to the places in order, and with nine numbers and more than nine places ⌘9 picks the last, as it picks Safari's
    /// last tab. [mac] `numbersMore` false (the Mac, Mac polish #18): More has no row in the Mac's sidebar (its pages are
    /// Tools and the Settings window's), so it takes no number; ⌘9 opened the old More list beside "Nothing Open".
    static func place(forShortcut index: Int, keys: Int, tags: [Int], numbersMore: Bool) -> Int? {
        let numbered = tags.indices.filter { numbersMore || tags[$0] != HQTab.more.rawValue }
        guard index < keys, index < numbered.count else { return nil }
        if keys == 9, index == 8, numbered.count > 9 { return numbered.last }
        return numbered[index]
    }

    /// [macpass-sidebar] The places no number picks (past the eighth, the last taking ⌘9), in order, More left out
    /// where it takes no number: View lists them under the numbered ones, so every sidebar page is in the menu bar.
    static func unnumbered(keys: Int, tags: [Int], numbersMore: Bool) -> [Int] {
        let picked = Set((0..<keys).compactMap { place(forShortcut: $0, keys: keys, tags: tags, numbersMore: numbersMore) })
        return tags.indices.filter { !picked.contains($0) && (numbersMore || tags[$0] != HQTab.more.rawValue) }
    }
}

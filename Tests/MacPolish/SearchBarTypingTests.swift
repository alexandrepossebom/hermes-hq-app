// [search-keys 2026-11-20] On macOS 27 a search bar keeps the first responder for itself (its field only draws the
// caret), so the checks for "a field has the keyboard" (type-to-chat, ⌘⌫ / ⌘↑ / ⌘↓ while typing, the arrows) must count
// a search bar as typing, through its field. Before, letters typed in Sessions' Search Chats went into the chat's
// message box.

import Testing
import UIKit
@testable import HermesHQNative

@MainActor
struct SearchBarTypingTests {
    @Test func aSearchBarTypesThroughItsField() {
        let bar = UISearchBar()
        #expect(bar.hqTypingInput === bar.searchTextField)
        bar.searchTextField.text = "plan"
        #expect(bar.hqTypingInput?.hasText == true)
    }

    @Test func fieldsTypeThemselvesAndOtherViewsDoNot() {
        let field = UITextField()
        let text = UITextView()
        #expect(field.hqTypingInput === field)
        #expect(text.hqTypingInput === text)
        #expect(UIView().hqTypingInput == nil)
        #expect(UIButton().hqTypingInput == nil)
    }
}

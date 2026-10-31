import AppKit
import SwiftUI

/// Number formatting and parsing for editable fields. Grouping separators are never displayed,
/// so a value like 1920 round-trips unchanged.
enum FieldFormat {
    static func string(_ value: Double, fractionDigits: ClosedRange<Int> = 0...2, locale: Locale = .current) -> String {
        value.formatted(.number.precision(.fractionLength(fractionDigits)).grouping(.never).locale(locale))
    }
    /// Returns nil for empty, non-numeric or non-finite text.
    static func number(from text: String, locale: Locale = .current) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let value = try? Double(trimmed, format: .number.locale(locale)), value.isFinite else { return nil }
        return value
    }
    /// Returns a whole number, or nil when the text is not one.
    static func integer(from text: String, locale: Locale = .current) -> Int? {
        guard let value = number(from: text, locale: locale), value.rounded() == value, abs(value) < Double(Int.max) else { return nil }
        return Int(value)
    }
}

/// Draft-versus-model bookkeeping for editable fields.
/// The draft counts as edited only when it differs from the last model text shown. An untouched field follows
/// outside changes (such as a canvas drag) even while focused, and is never applied, so it cannot write a stale value back.
struct DraftBuffer: Equatable {
    var draft: String
    private(set) var baseline: String
    init(_ text: String = "") { draft = text; baseline = text }
    var isEdited: Bool { draft != baseline }
    /// An outside change replaces the draft unless the user has started typing.
    mutating func modelChanged(to text: String) { if !isEdited { draft = text }; baseline = text }
    /// Shows `text` as the current, unedited value.
    mutating func show(_ text: String) { draft = text; baseline = text }
}

/// Edits a local draft and applies it on Return or when focus leaves the field, following the macOS convention.
/// The field can be cleared and retyped freely; a rejected value beeps and restores the current value.
struct DraftTextField: View {
    let title: String
    let value: String
    /// Returns false when the value is not accepted.
    let commit: (String) -> Bool
    @State private var buffer = DraftBuffer()
    @FocusState private var focused: Bool
    init(_ title: String, value: String, commit: @escaping (String) -> Bool) {
        self.title = title; self.value = value; self.commit = commit
    }
    var body: some View {
        TextField(title, text: $buffer.draft)
            .focused($focused)
            .onSubmit { apply(beep: true) }
            .onAppear { buffer.show(value) }
            .onChange(of: value) { _, new in buffer.modelChanged(to: new) }
            .onChange(of: focused) { _, isFocused in if !isFocused { apply(beep: true) } }
            .onDisappear { apply(beep: false) }
            .onExitCommand { buffer.show(value); focused = false }
    }
    private func apply(beep: Bool) {
        guard buffer.isEdited else { return }
        let text = buffer.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == value { buffer.show(value) }
        else if commit(text) { buffer.show(text) }
        else { if beep { NSSound.beep() }; buffer.show(value) }
    }
}

/// Numeric variant of `DraftTextField`. The draft is parsed only when it is applied.
struct DraftNumberField: View {
    let title: String
    let value: Double
    let fractionDigits: ClosedRange<Int>
    /// Returns false when the value is not accepted.
    let commit: (Double) -> Bool
    @State private var buffer = DraftBuffer()
    @FocusState private var focused: Bool
    init(_ title: String, value: Double, fractionDigits: ClosedRange<Int> = 0...2, commit: @escaping (Double) -> Bool) {
        self.title = title; self.value = value; self.fractionDigits = fractionDigits; self.commit = commit
    }
    /// Whole-number field, for pixel sizes.
    init(_ title: String, integer: Int, commit: @escaping (Int) -> Bool) {
        self.init(title, value: Double(integer), fractionDigits: 0...0) { value in
            guard value.rounded() == value, abs(value) < Double(Int.max) else { return false }
            return commit(Int(value))
        }
    }
    private var formatted: String { FieldFormat.string(value, fractionDigits: fractionDigits) }
    var body: some View {
        TextField(title, text: $buffer.draft)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .focused($focused)
            .onSubmit { apply(beep: true) }
            .onAppear { buffer.show(formatted) }
            .onChange(of: value) { _, new in buffer.modelChanged(to: FieldFormat.string(new, fractionDigits: fractionDigits)) }
            .onChange(of: focused) { _, isFocused in if !isFocused { apply(beep: true) } }
            .onDisappear { apply(beep: false) }
            .onExitCommand { buffer.show(formatted); focused = false }
    }
    private func apply(beep: Bool) {
        guard buffer.isEdited else { return }
        guard let number = FieldFormat.number(from: buffer.draft) else { reject(beep); return }
        // Compare at display precision so re-applying an unchanged, rounded value is a no-op.
        let shown = FieldFormat.string(number, fractionDigits: fractionDigits)
        if shown == formatted { buffer.show(formatted) }
        else if commit(number) { buffer.show(shown) }
        else { reject(beep) }
    }
    private func reject(_ beep: Bool) { if beep { NSSound.beep() }; buffer.show(formatted) }
}

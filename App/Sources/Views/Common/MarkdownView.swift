import PVEKit
import SwiftUI

/// Renders notes as Markdown like the PVE WebUI: headings, paragraphs, bullet / numbered lists,
/// quotes, fenced code blocks and horizontal rules; inline emphasis, code and links through
/// `AttributedString(markdown:)`.
struct MarkdownView: View {
    let text: String

    enum Block: Hashable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet(String)
        case numbered(String, String)
        case quote(String)
        case code(String)
        case rule
    }

    static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(rawLine)
                continue
            }
            if line.isEmpty {
                flush()
                continue
            }
            if let level = line.firstIndex(where: { $0 != "#" }).map({ line.distance(from: line.startIndex, to: $0) }),
               (1...6).contains(level), line.dropFirst(level).first == " " {
                flush()
                blocks.append(.heading(level: level, text: String(line.dropFirst(level + 1))))
            } else if line == "---" || line == "***" || line == "___" {
                flush()
                blocks.append(.rule)
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                flush()
                blocks.append(.bullet(String(line.dropFirst(2))))
            } else if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
                      line[line.index(after: dot)...].hasPrefix(" ") {
                flush()
                blocks.append(.numbered(String(line[..<dot]), String(line[line.index(dot, offsetBy: 2)...])))
            } else if line.hasPrefix(">") {
                flush()
                blocks.append(.quote(line.dropFirst().trimmingCharacters(in: .whitespaces)))
            } else {
                paragraph.append(line)
            }
        }
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
        case .paragraph(let text):
            Text(Self.inline(text))
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: "•")
                Text(Self.inline(text))
            }
        case .numbered(let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: "\(number).").monospacedDigit()
                Text(Self.inline(text))
            }
        case .quote(let text):
            Text(Self.inline(text))
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle().fill(.tertiary).frame(width: 3)
                }
        case .code(let text):
            Text(verbatim: text)
                .font(.system(.footnote, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        case .rule:
            Divider()
        }
    }
}

/// 「备注」 section: Markdown when viewing, plain text when editing (`description` of the config).
struct NotesSection: View {
    let canEdit: Bool
    let missingText: String?
    let load: () async throws -> String
    let save: (String) async throws -> Void

    @State private var notes: String?
    @State private var error: String?
    @State private var editing = false

    var body: some View {
        Section {
            if let notes {
                if notes.isEmpty {
                    Text("暂无备注").foregroundStyle(.secondary)
                } else {
                    MarkdownView(text: notes)
                        .accessibilityIdentifier("notes-markdown")
                }
            } else if let error {
                Text(error).font(.footnote).foregroundStyle(.secondary)
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        } header: {
            HStack {
                Text("备注")
                Spacer()
                Button("编辑") { editing = true }
                    .font(.subheadline)
                    .textCase(nil)
                    .disabled(!canEdit || notes == nil)
                    .accessibilityIdentifier("notes-edit")
            }
        } footer: {
            if let missingText {
                NoPermissionLabel(text: "无法编辑备注：\(missingText)")
            }
        }
        .task { await reload() }
        .sheet(isPresented: $editing) {
            NotesEditor(original: notes ?? "") { text in
                try await save(text)
                await reload()
            }
        }
    }

    private func reload() async {
        do {
            notes = try await load()
            error = nil
        } catch {
            if notes == nil { self.error = ErrorText.message(for: error) }
        }
    }
}

struct NotesEditor: View {
    let original: String
    let onSave: (String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 240)
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("notes-editor")
                } footer: {
                    Text("支持 Markdown。保存后写入配置的 description。")
                }
                if let error {
                    Section { ErrorBanner(message: error) }
                }
            }
            .navigationTitle("编辑备注")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task {
                            saving = true
                            defer { saving = false }
                            do {
                                try await onSave(text)
                                dismiss()
                            } catch {
                                self.error = ErrorText.message(for: error)
                            }
                        }
                    }
                    .disabled(saving || text == original)
                }
            }
            .onAppear { text = original }
        }
    }
}

/// Footer line listing the privileges an action lacks.
struct MissingPermissionLabel: View {
    let action: String
    let missing: [PermissionNeed]

    var body: some View {
        if !missing.isEmpty {
            NoPermissionLabel(text: "无法\(action)：\(ServerConnection.describe(missing))")
        }
    }
}

/// Text field for an optional integer (empty = nil).
struct OptionalIntField: View {
    let title: LocalizedStringKey
    @Binding var value: Int?
    var prompt: String?

    var body: some View {
        LabeledContent(title) {
            TextField(prompt ?? "", text: Binding(
                get: { value.map(String.init) ?? "" },
                set: { value = Int($0.trimmingCharacters(in: .whitespaces)) }
            ))
            .keyboardType(.numberPad)
            .multilineTextAlignment(.trailing)
        }
    }
}

/// Text field for an optional decimal number (empty = nil).
struct OptionalDoubleField: View {
    let title: LocalizedStringKey
    @Binding var value: Double?
    var prompt: String?

    var body: some View {
        LabeledContent(title) {
            TextField(prompt ?? "", text: Binding(
                get: { value.map { WizardValidation.number($0) } ?? "" },
                set: { value = Double($0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) }
            ))
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.trailing)
        }
    }
}

/// Text field for a required integer.
struct IntField: View {
    let title: LocalizedStringKey
    @Binding var value: Int

    var body: some View {
        LabeledContent(title) {
            TextField("", value: $value, format: .number.grouping(.never))
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
        }
    }
}

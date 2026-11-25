import SwiftUI
import AppKit

/// WinHex-style search panel, hosted in its own draggable floating window so
/// the hex view stays usable while a scan runs.
///
/// Both buttons scan on a background thread and report to the floating
/// progress palette. `Find Next` stops at the first hit, closes this dialog and
/// lists the hit in the pane in the middle of the window; `Find All` keeps
/// scanning and lists every hit there.
struct SearchView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.t("Search")).font(.headline)

            Picker(L.t("Type"), selection: $state.searchKind) {
                ForEach(SearchPatternKind.allCases) { kind in
                    Text(L.t(kind.rawValue)).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack {
                Text(state.searchKind == .hex ? L.t("Hex bytes to find:") : L.t("Text to find:"))
                    .frame(width: 130, alignment: .leading)
                TextField(state.searchKind == .hex ? L.t("e.g. 4D 5A ?? 00") : L.t("text to search"),
                          text: state.searchKind == .hex ? $state.searchHex : $state.searchText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            if state.searchKind == .hex {
                HStack {
                    Toggle(L.t("Wildcard byte (hex):"), isOn: $state.searchWildcardIsOn)
                    TextField("3F", text: $state.searchWildcardByte)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 64)
                        .disabled(!state.searchWildcardIsOn)
                    Spacer()
                }
                Text(L.t("Every occurrence of this byte matches any value. Bytes typed as ?? are always wildcards."))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Toggle(L.t("Case insensitive"), isOn: $state.searchCaseInsensitive)
            }

            HStack {
                Text(L.t("Search:"))
                    .frame(width: 130, alignment: .leading)
                Picker("", selection: $state.searchDirection) {
                    ForEach(SearchDirection.allCases) { direction in
                        Text(L.t(direction.rawValue)).tag(direction)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                Spacer()
            }

            HStack {
                Toggle(L.t("Offset"), isOn: $state.searchAlignmentIsOn)
                    .frame(width: 130, alignment: .leading)
                Text(L.t("mod")).foregroundColor(.secondary)
                TextField("512", text: $state.searchAlignmentModulus)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)
                    .disabled(!state.searchAlignmentIsOn)
                Text("=").foregroundColor(.secondary)
                TextField("0", text: $state.searchAlignmentRemainder)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)
                    .disabled(!state.searchAlignmentIsOn)
                Spacer()
            }

            Toggle(L.t("Search in selection only"), isOn: $state.searchSelectionOnly)
                .disabled(!state.hasSelection)

            HStack {
                Toggle(L.t("List results (limit)"), isOn: $state.searchLimitIsOn)
                    .frame(width: 200, alignment: .leading)
                TextField("10000", text: $state.searchLimitText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .disabled(!state.searchLimitIsOn)
                Spacer()
            }

            if !state.searchStatus.isEmpty {
                Text(state.searchStatus)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                Button(L.t("Find Next")) { state.searchFindNext() }
                    .disabled(state.isSearching || !state.searchPatternIsValid)
                Button(L.t("Find All")) { state.searchFindAll() }
                    .disabled(state.isSearching || !state.searchPatternIsValid)
                if state.isSearching {
                    Button(L.t("Stop")) { state.cancelSearch() }
                }
                Spacer()
                Button(L.t("Close")) {
                    // A running scan keeps going in its own progress palette.
                    state.showSearch = false
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 560, alignment: .topLeading)
    }
}

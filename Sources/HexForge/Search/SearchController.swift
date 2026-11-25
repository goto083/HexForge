import Foundation
import AppKit

/// UI-facing search actions.
///
/// The stored properties these drive live in `AppState`; keeping the logic in a
/// separate file means the whole search feature is readable in one place.
extension AppState {

    // MARK: - Opening

    func openSearch() {
        if searchHex.isEmpty && searchText.isEmpty {
            searchHex = findHex
            searchText = findText
            searchKind = findMode == .hex ? .hex : .text
        }
        searchStatus = ""
        searchResults = []
        searchTotalFound = 0
        showSearch = true
    }

    // MARK: - Options

    /// A snapshot of the dialog state, in the shape the engine expects.
    func searchOptionsNow() -> SearchOptions {
        var options = SearchOptions()
        options.kind = searchKind
        options.hexText = searchHex
        options.text = searchText
        options.caseInsensitive = searchCaseInsensitive
        options.wildcardByte = searchWildcardIsOn ? Self.searchByte(searchWildcardByte) : nil
        options.direction = searchDirection
        options.selectionOnly = searchSelectionOnly

        if searchAlignmentIsOn {
            let modulus = Int(searchAlignmentModulus.trimmingCharacters(in: .whitespaces))
            options.alignmentModulus = (modulus ?? 0) > 0 ? modulus : nil
            options.alignmentRemainder = max(0, Int(searchAlignmentRemainder.trimmingCharacters(in: .whitespaces)) ?? 0)
        }
        if searchLimitIsOn {
            options.maxResults = max(1, parsedByteCount(searchLimitText))
        }
        return options
    }

    func searchPatternNow() -> BytePattern? {
        SearchEngine.makePattern(searchOptionsNow())
    }

    /// True while the query would produce a pattern the engine can run.
    var searchPatternIsValid: Bool { searchPatternNow() != nil }

    private var searchRangeNow: Range<Int> {
        searchSelectionOnly && hasSelection ? selectionRange : 0..<size
    }

    /// Parses a single byte written as hex, e.g. `3F` or `0x3f`.
    static func searchByte(_ text: String) -> UInt8? {
        var cleaned = text.lowercased()
        for token in ["0x", " ", "\t", "$"] {
            cleaned = cleaned.replacingOccurrences(of: token, with: "")
        }
        return UInt8(cleaned, radix: 16)
    }

    // MARK: - Find next / previous

    /// Moves to the next match in the chosen direction, wrapping at the ends.
    func searchFindNext() {
        guard let pattern = searchPatternNow() else {
            setSearchStatus(L.t("Invalid search pattern"))
            return
        }
        guard size > 0 else { return }

        let options = searchOptionsNow()
        let range = searchRangeNow
        guard range.count >= pattern.count else {
            setSearchStatus(L.t("Not found"))
            return
        }

        var hit: Int?
        var wrapped = false

        if options.direction == .forward {
            let start = cursor + 1
            if start < range.upperBound {
                hit = SearchEngine.findAll(pattern: pattern, document: document,
                                           in: start..<range.upperBound,
                                           options: options, limit: 1).first
                if hit == nil, range.lowerBound < start {
                    hit = SearchEngine.findAll(pattern: pattern, document: document,
                                               in: range.lowerBound..<start,
                                               options: options, limit: 1).first
                    wrapped = hit != nil
                }
            } else {
                hit = SearchEngine.findAll(pattern: pattern, document: document,
                                           in: range, options: options, limit: 1).first
                wrapped = hit != nil
            }
        } else {
            let end = max(range.lowerBound, min(cursor, range.upperBound))
            if range.lowerBound < end {
                hit = SearchEngine.findLast(pattern: pattern, document: document,
                                            in: range.lowerBound..<end, options: options)
                if hit == nil, end + 1 < range.upperBound {
                    hit = SearchEngine.findLast(pattern: pattern, document: document,
                                                in: (end + 1)..<range.upperBound, options: options)
                    wrapped = hit != nil
                }
            } else {
                hit = SearchEngine.findLast(pattern: pattern, document: document,
                                            in: range, options: options)
                wrapped = hit != nil
            }
        }

        guard let offset = hit else {
            setSearchStatus(L.t("Not found"))
            return
        }

        selectMatch(at: offset, length: pattern.count)
        searchWrapped = wrapped
        let hexOffset = String(offset, radix: 16).uppercased()
        setSearchStatus(wrapped
                        ? L.f("Match at 0x%@ (wrapped)", hexOffset)
                        : L.f("Match at 0x%@", hexOffset))
    }

    // MARK: - Find all

    /// Scans the whole range on a background thread, reporting live progress
    /// in a floating WinHex-style window so the main window stays usable.
    func searchFindAll() {
        guard let pattern = searchPatternNow() else {
            setSearchStatus(L.t("Invalid search pattern"))
            return
        }
        guard size > 0, !isSearching else { return }

        let options = searchOptionsNow()
        let range = searchRangeNow
        let target = document
        let progressState = searchProgressState
        let queryText = searchQueryDescription(options)

        isSearching = true
        searchCancelled = false
        searchToken &+= 1
        let token = searchToken
        searchResults = []
        searchTotalFound = 0
        selectedHitOffset = nil
        searchProgress = 0
        searchStatus = L.t("Searching…")

        // WinHex behaviour: the find dialog steps aside at once and a small
        // floating progress palette takes over, leaving the hex view live.
        showSearch = false
        progressState.reset()
        progressState.isSearching = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Throttle: the scan visits one 1 MiB window at a time, which on a
            // 60 GB device would otherwise be tens of thousands of main-queue
            // hops and make the UI stutter.
            var lastReport = Date.distantPast

            let hits = SearchEngine.findAll(
                pattern: pattern,
                document: target,
                in: range,
                options: options,
                limit: options.maxResults,
                progress: { fraction, scanned, found in
                    let now = Date()
                    guard fraction >= 1 || now.timeIntervalSince(lastReport) >= 0.05 else { return }
                    lastReport = now
                    DispatchQueue.main.async {
                        guard let self = self, self.searchToken == token else { return }
                        progressState.fraction = fraction
                        progressState.scanOffset = scanned
                        progressState.resultCount = found
                    }
                },
                isCancelled: { [weak self] in
                    guard let self = self else { return true }
                    return self.searchCancelled
                }
            )

            DispatchQueue.main.async {
                guard let self = self, self.searchToken == token else { return }
                let wasCancelled = self.searchCancelled

                self.isSearching = false
                progressState.isSearching = false
                progressState.fraction = 1
                progressState.resultCount = hits.count
                self.searchProgress = 1
                self.searchResults = hits.map { SearchHit(offset: $0) }
                self.searchTotalFound = hits.count

                if wasCancelled {
                    self.setSearchStatus(hits.isEmpty
                                         ? L.t("Search cancelled")
                                         : L.f("Search stopped · %d match(es)", hits.count))
                } else if hits.isEmpty {
                    self.setSearchStatus(L.t("No matches found"))
                } else if options.maxResults > 0 && hits.count >= options.maxResults {
                    self.setSearchStatus(L.f("Found %d match(es) (limit reached)", hits.count))
                } else {
                    self.setSearchStatus(L.f("Found %d match(es)", hits.count))
                }

                // Hits go into the docked list above the hex view; clicking a
                // row jumps straight to that offset.
                if !hits.isEmpty {
                    self.showHitList = true
                    if let first = hits.first {
                        self.selectMatch(at: first, length: pattern.count)
                        self.selectedHitOffset = first
                    }
                }

                if !wasCancelled {
                    self.presentSearchCompletion(query: queryText, count: hits.count)
                }
            }
        }
    }

    /// Text shown in the completion alert, e.g. `E7E8` or `hello`.
    private func searchQueryDescription(_ options: SearchOptions) -> String {
        switch options.kind {
        case .hex:
            return options.hexText
                .replacingOccurrences(of: " ", with: "")
                .uppercased()
        case .text:
            return options.text
        }
    }

    /// WinHex closes every search with a small "搜索完毕" alert.
    private func presentSearchCompletion(query: String, count: Int) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = L.t("Search complete")
            if count > 0 {
                alert.informativeText = L.f("%@ was found %d time(s).", query, count)
            } else {
                alert.informativeText = L.t("No matches found.")
            }
            alert.addButton(withTitle: L.t("OK"))
            alert.runModal()
        }
    }

    func cancelSearch() {
        searchCancelled = true
    }

    /// Ctrl+M: flips between the search-hit list and the normal file view.
    func toggleSearchResults() {
        guard !searchResults.isEmpty else { return }
        showHitList.toggle()
    }

    // MARK: - Results list

    func jumpToSearchHit(_ hit: SearchHit) {
        let length = searchPatternNow()?.count ?? 1
        scrollCentered = true
        selectMatch(at: hit.offset, length: length)
        selectedHitOffset = hit.offset
        setSearchStatus(L.f("Match at 0x%@", String(hit.offset, radix: 16).uppercased()))
    }

    /// Hex dump of the matched bytes at `hit.offset`, for the hit list rows.
    /// Reads lazily (only visible rows call this) and caps at 16 bytes.
    func searchHitPreview(_ hit: SearchHit) -> String {
        let length = min(searchPatternNow()?.count ?? 0, 16)
        guard length > 0, hit.offset >= 0, hit.offset + length <= size else { return "" }
        return document.bytes(in: hit.offset..<(hit.offset + length))
            .map { String(format: "%02X", $0) }
            .joined(separator: " ")
    }

    private func setSearchStatus(_ text: String) {
        searchStatus = text
        statusMessage = text
    }
}

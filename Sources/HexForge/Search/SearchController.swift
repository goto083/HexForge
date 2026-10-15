import Foundation

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

    /// Scans the whole range on a background thread, listing hits as it goes.
    func searchFindAll() {
        guard let pattern = searchPatternNow() else {
            setSearchStatus(L.t("Invalid search pattern"))
            return
        }
        guard size > 0, !isSearching else { return }

        let options = searchOptionsNow()
        let range = searchRangeNow
        let target = document

        isSearching = true
        searchCancelled = false
        searchToken &+= 1
        let token = searchToken
        searchProgress = 0
        searchResults = []
        searchTotalFound = 0
        searchStatus = L.t("Searching…")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let hits = SearchEngine.findAll(
                pattern: pattern,
                document: target,
                in: range,
                options: options,
                limit: options.maxResults,
                progress: { fraction in
                    DispatchQueue.main.async {
                        guard let self = self, self.searchToken == token else { return }
                        self.searchProgress = fraction
                    }
                },
                isCancelled: { [weak self] in
                    guard let self = self else { return true }
                    return self.searchCancelled
                }
            )

            DispatchQueue.main.async {
                guard let self = self, self.searchToken == token else { return }
                self.isSearching = false
                self.searchProgress = 1
                self.searchResults = hits.map { SearchHit(offset: $0) }
                self.searchTotalFound = hits.count

                if self.searchCancelled {
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

                if let first = hits.first {
                    self.selectMatch(at: first, length: pattern.count)
                }
            }
        }
    }

    func cancelSearch() {
        searchCancelled = true
    }

    // MARK: - Results list

    func jumpToSearchHit(_ hit: SearchHit) {
        let length = searchPatternNow()?.count ?? 1
        selectMatch(at: hit.offset, length: length)
        setSearchStatus(L.f("Match at 0x%@", String(hit.offset, radix: 16).uppercased()))
    }

    private func setSearchStatus(_ text: String) {
        searchStatus = text
        statusMessage = text
    }
}

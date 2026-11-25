import SwiftUI

/// Live state for the floating search-progress window.
///
/// Kept separate from `AppState` on purpose: the scan reports progress every
/// few dozen milliseconds, and publishing that on `AppState` would re-render
/// the whole main window (hex view included) on every tick — which is what
/// made long scans feel frozen.
final class SearchProgressState: ObservableObject {
    /// Drives the panel's visibility.
    @Published var isSearching = false
    /// 0…1 scan fraction.
    @Published var fraction: Double = 0
    /// Absolute byte offset the scan has reached.
    @Published var scanOffset: Int = 0
    /// Hits recorded so far. Once this is non-zero WinHex swaps the sector
    /// readout for the running result count.
    @Published var resultCount: Int = 0

    func reset() {
        isSearching = false
        fraction = 0
        scanOffset = 0
        resultCount = 0
    }
}

/// WinHex-style "searching" palette: status line, progress bar and percentage.
///
/// The window around it is a floating, non-activating `NSPanel`, so the main
/// window stays fully usable and the palette can be dragged aside while a
/// multi-gigabyte device is being scanned.
struct SearchProgressView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var progress: SearchProgressState

    init(progress: SearchProgressState) {
        _progress = ObservedObject(wrappedValue: progress)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(statusText)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 10) {
                ProgressView(value: min(max(progress.fraction, 0), 1))
                    .progressViewStyle(.linear)
                Text("\(percentText)%")
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 40, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// WinHex switches from "正在扇区 N 中搜索…" to "正在搜索… N 个结果" as soon
    /// as the first hit is recorded.
    private var statusText: String {
        if progress.resultCount > 0 {
            return L.f("Searching… %d result(s)", progress.resultCount)
        }
        return L.f("Searching sector %d…", currentSector)
    }

    private var percentText: String {
        String(Int((min(max(progress.fraction, 0), 1) * 100).rounded()))
    }

    /// Sector containing the current scan position, addressed like the hex
    /// view: volume-relative once a file system is parsed, otherwise absolute.
    private var currentSector: Int {
        let unit = max(1, state.sectorSize)
        let relative = progress.scanOffset - state.displayBase
        return relative >= 0 ? relative / unit : progress.scanOffset / unit
    }
}

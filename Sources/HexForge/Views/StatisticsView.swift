import SwiftUI

struct StatisticsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 16)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Byte Statistics & Histogram").font(.headline)
            Text("Counts how often each of the 256 byte values occurs across the selection or the whole file.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 12) {
                Picker("Scope", selection: $state.statisticsScopeIsSelection) {
                    Text("Whole file").tag(false)
                    Text("Selection").tag(true)
                }
                .pickerStyle(.segmented)
                .disabled(!state.hasSelection)
                .frame(width: 220)

                Button {
                    state.computeStatistics(overSelection: state.statisticsScopeIsSelection)
                } label: {
                    Label("Analyse", systemImage: "chart.bar.fill")
                }
                .disabled(!state.hasContent || state.isComputingStatistics)

                if state.isComputingStatistics {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }

            if !state.statisticsStatus.isEmpty {
                Text(state.statisticsStatus)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            if state.statistics.totalBytes == 0 {
                Text(state.hasContent ? "Run Analyse to build the histogram." : "Open a file first.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        summary
                        histogram
                        Divider()
                        topList
                    }
                    .padding(.trailing, 8)
                }
            }
        }
        .padding(20)
        .frame(width: 720, height: 640)
    }

    // MARK: - Summary

    private var summary: some View {
        let s = state.statistics
        return HStack(spacing: 12) {
            statBox("Bytes", state.byteCountString(s.totalBytes))
            statBox("Distinct values", "\(s.distinctValues) / 256")
            statBox("Max count", "\(s.maxCount)")
            statBox("Entropy", String(format: "%.3f bits/byte", s.entropy))
        }
    }

    private func statBox(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundColor(Color.secondary)
            Text(value).font(.system(size: 13, weight: .semibold, design: .monospaced))
        }
        .frame(minWidth: 120, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
    }

    // MARK: - Histogram

    private var histogram: some View {
        let s = state.statistics
        return VStack(alignment: .leading, spacing: 6) {
            Text("Histogram — 0x00 to 0xFF").font(.caption).foregroundColor(Color.secondary)
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(0..<256, id: \.self) { value in
                    cell(value, stats: s)
                }
            }
        }
    }

    private func cell(_ value: Int, stats: ByteStatistics) -> some View {
        let intensity = stats.intensity(for: value)
        let count = stats.counts[value]
        return ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.green.opacity(0.08 + 0.85 * intensity))
            VStack(spacing: 0) {
                Text(String(format: "%02X", value))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(intensity > 0.55 ? Color.white : Color.secondary)
                Text("\(count)")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(intensity > 0.55 ? Color.white.opacity(0.85) : Color.secondary.opacity(0.7))
            }
        }
        .frame(height: 30)
        .help(String(format: "0x%02X — %d byte(s), %.2f%% of range",
                     value, count, stats.fraction(for: value) * 100))
    }

    // MARK: - Top values

    private var topList: some View {
        let items = state.statistics.mostFrequent(limit: 10)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Most frequent byte values").font(.caption).foregroundColor(Color.secondary)
            ForEach(items) { f in
                HStack(spacing: 10) {
                    Text(String(format: "0x%02X", f.value))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 54, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15))
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.green.opacity(0.8))
                                .frame(width: max(2, geo.size.width * f.fraction))
                        }
                    }
                    .frame(height: 12)
                    Text("\(f.count)")
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 90, alignment: .trailing)
                    Text(String(format: "%.2f%%", f.fraction * 100))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color.secondary)
                        .frame(width: 64, alignment: .trailing)
                }
            }
        }
    }
}

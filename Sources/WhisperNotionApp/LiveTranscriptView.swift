import SwiftUI
import TranscriptionKit

/// The live transcript surface shown in the floating panel during a meeting.
/// Finalized segments stack newest-at-bottom with auto-scroll; the interim
/// (still-changing) line renders dimmed so the user reads it as provisional.
struct LiveTranscriptView: View {
    @ObservedObject var vm = RecorderViewModel.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
        }
        .frame(minWidth: 360, minHeight: 240)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(vm.isRecording ? Color.red : Color.secondary)
                .frame(width: 9, height: 9)
            Text(vm.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button(vm.isRecording ? "정지" : "녹음") { vm.toggle() }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(vm.finalized.enumerated()), id: \.offset) { _, seg in
                        Text(seg.text)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    if !vm.interim.isEmpty {
                        Text(vm.interim)
                            .font(.body)
                            .italic()
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("interim")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
            }
            .onChange(of: vm.finalized.count) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: vm.interim) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }
}

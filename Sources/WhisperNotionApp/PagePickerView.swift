import SwiftUI
import NotionSync

/// Shown when the user starts recording but hasn't chosen a target Notion page.
/// Lists the pages the integration can write to (granted during OAuth) with a
/// search filter, plus a paste-a-link field for when the list is long.
struct PagePickerView: View {
    let onPick: (NotionPageRef) -> Void
    let onRecordLocal: () -> Void

    @ObservedObject private var settings = SettingsStore.shared
    @State private var pages: [NotionPageRef] = []
    @State private var loading = true
    @State private var error: String?
    @State private var search = ""
    @State private var linkText = ""

    private var filtered: [NotionPageRef] {
        guard !search.isEmpty else { return pages }
        return pages.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("어느 Notion 페이지에 기록할까요?")
                .font(.headline)

            // Paste-a-link path (fast when you already have the URL).
            HStack {
                TextField("Notion 페이지 링크 붙여넣기", text: $linkText)
                    .textFieldStyle(.roundedBorder)
                Button("사용") {
                    if let id = PageIDParser.pageID(from: linkText) {
                        onPick(NotionPageRef(id: id, title: "링크로 지정한 페이지"))
                    } else {
                        error = "링크에서 페이지 ID를 찾지 못했습니다"
                    }
                }
                .disabled(linkText.isEmpty)
            }

            Divider()

            // Searchable list of granted pages.
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("페이지 검색", text: $search)
                    .textFieldStyle(.plain)
            }
            .padding(6)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

            if loading {
                HStack { ProgressView().controlSize(.small); Text("불러오는 중…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 16)
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.callout)
            } else if filtered.isEmpty {
                Text(pages.isEmpty ? "쓸 수 있는 페이지가 없습니다." : "검색 결과 없음")
                    .foregroundStyle(.secondary).font(.callout)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(filtered) { page in
                            Button { onPick(page) } label: {
                                HStack {
                                    Image(systemName: "doc.text")
                                    Text(page.title).lineLimit(1)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                                .padding(.vertical, 6).padding(.horizontal, 8)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 280)
            }

            Divider()
            HStack {
                Button("Notion 없이 녹음") { onRecordLocal() }
                Spacer()
                Button("새로고침") { Task { await load() } }.controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 420)
        .task { await load() }
    }

    private func load() async {
        loading = true; error = nil
        do {
            pages = try await settings.fetchPages()
        } catch {
            self.error = "페이지 목록을 불러오지 못했습니다: \(error.localizedDescription)"
        }
        loading = false
    }
}

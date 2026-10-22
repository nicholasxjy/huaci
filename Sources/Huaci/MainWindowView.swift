import HuaciCore
import SwiftUI

enum MainSection: String, CaseIterable, Identifiable {
    case translate
    case history
    case vocabulary

    var id: String { rawValue }

    var title: String {
        switch self {
        case .translate: return "翻译"
        case .history: return "历史"
        case .vocabulary: return "生词本"
        }
    }

    var symbol: String {
        switch self {
        case .translate: return "character.book.closed"
        case .history: return "clock"
        case .vocabulary: return "book"
        }
    }

    /// ⌘1, ⌘2, ⌘3.
    var keyEquivalent: String {
        String((Self.allCases.firstIndex(of: self) ?? 0) + 1)
    }
}

@MainActor
final class MainWindowState: ObservableObject {
    @Published var section: MainSection = .translate
}

/// The "划词" window: translate, history and vocabulary behind one sidebar.
struct MainWindowView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var state: MainWindowState

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { state.section }, set: { if let section = $0 { state.section = section } })) {
                ForEach(MainSection.allCases) { section in
                    HStack {
                        Label(section.title, systemImage: section.symbol)
                        Spacer()
                        Text("⌘\(section.keyEquivalent)").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .tag(section)
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) { ServiceStatusCard().padding(10) }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            Group {
                switch state.section {
                case .translate: TranslateView(state: model.inputTranslation)
                case .history: HistoryView()
                case .vocabulary: VocabularyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ignoresSafeArea(.container, edges: .top)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .tint(Theme.accent)
    }
}

/// Active service and model; opens the service settings, right-click switches.
private struct ServiceStatusCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Button {
            WindowRouter.shared.showSettings(.service)
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(model.isConfigured(settings.activeService) ? Theme.successDot : Theme.warningDot)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(settings.activeService.shortName).font(.system(size: 12, weight: .semibold))
                    Text(model.isConfigured(settings.activeService) ? model.activeModelName : "未配置，点击设置")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("翻译服务设置；右键切换服务")
        .contextMenu {
            ForEach(TranslationService.allCases) { service in
                Button {
                    settings.activeService = service
                } label: {
                    if settings.activeService == service { Label(service.shortName, systemImage: "checkmark") } else { Text(service.shortName) }
                }
            }
        }
    }
}

/// Rounded search field used above the history and vocabulary lists; ⌘F focuses it.
struct SearchField: View {
    @Binding var text: String
    let prompt: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("清除搜索")
            } else {
                Text("⌘F").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .background {
            Button("") { focused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }
}

enum Formatters {
    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// "今天 14:05"
    static func dayAndTime(_ date: Date) -> String {
        "\(DayGrouping.label(for: date)) \(time.string(from: date))"
    }
}

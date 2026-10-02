import AppKit
import GrizzyBotCore
import SwiftUI
import UniformTypeIdentifiers

struct RightPanelView: View {
    @Environment(AppStore.self) var store
    @Environment(\.rightPanelResizing) var isResizing

    @State var createName = ""
    @State var createTitle = ""
    @State var createDescription = ""

    @State var settingsName = ""
    @State var settingsTitle = ""
    @State var settingsDescription = ""
    @State var settingsInstructions = ""
    @State var settingsWorkingFolder = ""
    @State var confirmDelete = false
    @State var deleting = false
    @State var settingsError: String?
    @State var settingsLoadedFor: String?
    @State var redactedExport = true
    @State var skillsExpanded = false

    var body: some View {
        Group {
            if let panel = store.panel {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        switch panel {
                        case .computer:
                            computerPanel
                        case .create:
                            createPanel
                        case .settings:
                            settingsPanel
                        case .routine:
                            routinePanel
                        case .canvas:
                            CanvasPanelView()
                        case .artifact:
                            ArtifactPanelView()
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 17)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                }
                .grizzyScroll()
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                Color.clear
            }
        }
        .padding(.top, 28) // clear traffic lights under fullSizeContentView
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }

    var bot: Bot? { store.activeBot }
    var computer: ComputerStatus? {
        guard let id = bot?.id else { return nil }
        return store.computers[id]
    }


    // MARK: - Shared

    func panelHeader(left: String, showGear: Bool) -> some View {
        HStack {
            Text(left)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            if showGear {
                Button {
                    store.openPanel(.settings)
                } label: {
                    Text("⚙")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textBright)
                }
                .buttonStyle(.plain)
            }
            closeButton
        }
        .padding(.bottom, 16)
    }

    var closeButton: some View {
        Button {
            store.openPanel(nil)
        } label: {
            Text("✕")
                .font(.system(size: 15))
                .foregroundStyle(Theme.textBright)
        }
        .buttonStyle(.plain)
    }
}

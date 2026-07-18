import AppKit
import HoloCore
import SwiftUI
import UniformTypeIdentifiers

struct ZoneActionsView: View {
    @ObservedObject var model: AppModel
    @State private var confirmDelete = false

    var body: some View {
        Group {
            if let profile = model.selectedProfile {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Assign actions")
                            .font(.title.weight(.semibold))
                        Text("Each accepted tap runs its assigned action. Changes save automatically.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Form {
                        Section("Left of MacBook") {
                            ForEach(sortedConfigurations(profile, isLeft: true)) { configuration in
                                ZoneActionRow(
                                    configuration: configuration,
                                    onChange: { action in
                                        model.updateAction(for: configuration.zone, action: action)
                                    },
                                    onTest: model.testAction,
                                    onError: { error in
                                        model.errorMessage = "The action could not be assigned. \(error.localizedDescription)"
                                    }
                                )
                                .id("\(profile.id)-\(configuration.zone.rawValue)")
                            }
                        }

                        Section("Right of MacBook") {
                            ForEach(sortedConfigurations(profile, isLeft: false)) { configuration in
                                ZoneActionRow(
                                    configuration: configuration,
                                    onChange: { action in
                                        model.updateAction(for: configuration.zone, action: action)
                                    },
                                    onTest: model.testAction,
                                    onError: { error in
                                        model.errorMessage = "The action could not be assigned. \(error.localizedDescription)"
                                    }
                                )
                                .id("\(profile.id)-\(configuration.zone.rawValue)")
                            }
                        }

                        Section("Automation") {
                            Label("Use Run Shortcut for multi-step workflows such as opening Claude and starting a voice workflow.", systemImage: "command")
                            Label("Shell commands run through /bin/zsh with Holo's current macOS permissions.", systemImage: "terminal")
                            Label("Screenshot actions copy the result and may request Screen Recording access.", systemImage: "camera.viewfinder")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        Section {
                            HStack {
                                Text("Profile: \(profile.name)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Delete Profile", role: .destructive) {
                                    confirmDelete = true
                                }
                            }
                        }
                    }

                    .formStyle(.grouped)
                }
                .frame(maxWidth: 780, alignment: .leading)
                .padding(36)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("No Desk Profile", systemImage: "macbook")
                } description: {
                    Text("Calibrate the four zones before assigning actions.")
                } actions: {
                    Button("Open Calibration") { model.section = .calibrate }
                        .holoPrimaryButton()
                }
            }
        }
        .background(HoloTheme.background)
        .confirmationDialog("Delete this desk profile?", isPresented: $confirmDelete) {
            Button("Delete Profile", role: .destructive) { model.deleteSelectedProfile() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The saved calibration and its four actions will be removed.")
        }
    }

    private func sortedConfigurations(_ profile: HoloProfile, isLeft: Bool) -> [ZoneConfiguration] {
        profile.zones
            .filter { $0.zone.isLeft == isLeft }
            .sorted { $0.zone.verticalIndex < $1.zone.verticalIndex }
    }
}

private struct ZoneActionRow: View {
    let configuration: ZoneConfiguration
    let onChange: (ZoneActionConfiguration) -> Bool
    let onTest: (ZoneActionConfiguration) -> Void
    let onError: (Error) -> Void
    @State private var action: ZoneActionConfiguration
    @State private var isRevertingFailedSave = false

    private let sounds = ["Tink", "Pop", "Ping", "Glass", "Funk", "Morse", "Purr", "Sosumi"]

    init(
        configuration: ZoneConfiguration,
        onChange: @escaping (ZoneActionConfiguration) -> Bool,
        onTest: @escaping (ZoneActionConfiguration) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.configuration = configuration
        self.onChange = onChange
        self.onTest = onTest
        self.onError = onError
        _action = State(initialValue: configuration.action)
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 12) {
                Picker("Action", selection: $action.kind) {
                    ForEach(ZoneActionKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(width: 190)
                .accessibilityLabel("Action for \(zoneDescription)")

                detailControl
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button("Test", systemImage: "play.fill") {
                    onTest(action)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(!canTest)
                .help(canTest ? "Test this action" : "Finish configuring this action before testing")
                .accessibilityLabel("Test action for \(zoneDescription)")
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(configuration.zone.positionName)
                    .font(.body.weight(.medium))
                Text(configuration.zone.isLeft ? "Left side" : "Right side")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 86, alignment: .leading)
        }
        .padding(.vertical, 4)
        .onChange(of: action) { oldValue, newValue in
            if isRevertingFailedSave {
                isRevertingFailedSave = false
                return
            }
            if !onChange(newValue) {
                isRevertingFailedSave = true
                action = oldValue
            }
        }
    }

    private var canTest: Bool {
        LocalActionPlanner.command(for: action) != nil
    }

    private var zoneDescription: String {
        "\(configuration.zone.positionName), \(configuration.zone.isLeft ? "left" : "right") side"
    }

    @ViewBuilder
    private var detailControl: some View {
        switch action.kind {
        case .none:
            Text("Highlight only")
                .foregroundStyle(.secondary)
        case .sound:
            Picker("Sound", selection: $action.soundName) {
                ForEach(sounds, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: 180)
            .accessibilityLabel("Sound to play")
        case .copyText:
            TextField("Text to copy", text: $action.text)
        case .speakText:
            TextField("Words to speak", text: $action.text)
        case .openURL:
            TextField("Website address", text: $action.text, prompt: Text("https://example.com"))
        case .runShortcut:
            TextField("Shortcut name", text: $action.text, prompt: Text("Start Claude listening"))
        case .openApplication:
            Button {
                chooseApplication()
            } label: {
                Label(action.text.isEmpty ? "Choose Application…" : action.text, systemImage: "app")
                    .lineLimit(1)
            }
            .holoSecondaryButton()
        case .openItem:
            Button {
                chooseItem()
            } label: {
                Label(action.text.isEmpty ? "Choose File or Folder…" : action.text, systemImage: "doc")
                    .lineLimit(1)
            }
            .holoSecondaryButton()
        case .runShellCommand:
            VStack(alignment: .leading, spacing: 3) {
                TextField("Shell command", text: $action.text, prompt: Text("open -a Claude"))
                    .font(.system(.body, design: .monospaced))
                Text("Runs automatically after an accepted tap")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        case .screenshotClipboard:
            Label("All displays → Clipboard", systemImage: "rectangle.on.rectangle")
                .foregroundStyle(.secondary)
        case .screenshotSelection:
            Label("Choose an area → Clipboard", systemImage: "viewfinder")
                .foregroundStyle(.secondary)
        }
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = "Choose an application"
        panel.prompt = "Assign"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        saveBookmark(for: url, displayName: url.deletingPathExtension().lastPathComponent)
    }

    private func chooseItem() {
        let panel = NSOpenPanel()
        panel.title = "Choose a file or folder"
        panel.prompt = "Assign"
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        saveBookmark(for: url, displayName: url.lastPathComponent)
    }

    private func saveBookmark(for url: URL, displayName: String) {
        do {
            action.bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            action.text = displayName
        } catch {
            action.bookmarkData = nil
            action.text = ""
            onError(error)
        }
    }
}

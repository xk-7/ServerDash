import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct SessionImportWizard: View {
    private enum Step: Int {
        case source
        case input
        case preview
        case result
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Query(sort: \IdentityRecord.name) private var identities: [IdentityRecord]

    let existingServers: [ServerRecord]
    var onComplete: ((SessionImportResult) -> Void)?

    @State private var step: Step = .source
    @State private var source: SessionTransferSource = .automatic
    @State private var showingFileImporter = false
    @State private var preview: SessionImportPreview?
    @State private var selectedIDs = Set<UUID>()
    @State private var duplicateOverrideIDs = Set<UUID>()
    @State private var identityMappingIDs: [UUID: UUID] = [:]
    @State private var importPlaintextPasswords = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var result: SessionImportResult?
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .source: sourceView
                case .input: inputView
                case .preview: previewView
                case .result: resultView
                }
            }
            .navigationTitle(navigationTitle)
            .toolbar { toolbarContent }
        }
        .sessionWizardFrame()
        .interactiveDismissDisabled(isWorking)
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.item, .folder],
            allowsMultipleSelection: true,
            onCompletion: handleFileSelection
        )
        .alert("导入失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onDisappear {
            loadTask?.cancel()
            preview?.candidates.forEach { $0.credential?.clear() }
        }
    }

    private var navigationTitle: String {
        switch step {
        case .source: "选择来源"
        case .input: "选择配置"
        case .preview: "预览导入"
        case .result: "导入完成"
        }
    }

    private var sourceView: some View {
        List(SessionTransferSource.allCases) { item in
            Button {
                source = item
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: item.symbol)
                        .font(.title3)
                        .foregroundStyle(item == source ? Color.appAccent : .secondary)
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title).font(.headline).foregroundStyle(.primary)
                        Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if item == source {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.appAccent)
                    }
                }
                .contentShape(Rectangle())
                .frame(minHeight: 48)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(item.title)，\(item.subtitle)")
            .accessibilityAddTraits(item == source ? .isSelected : [])
        }
    }

    private var inputView: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(Color.appAccent)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("从 \(source.title) 导入").font(.title2.bold())
                Text("选择配置文件、导出文件、配置目录或 ZIP。文件只在本次导入期间读取。")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 520)
            }
            Button("选择配置文件或目录", systemImage: "folder") {
                showingFileImporter = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(minHeight: 44)

            if source.supportsLocalDiscovery {
                Button("读取本机配置目录", systemImage: "sparkle.magnifyingglass") {
                    inspectDiscoveredFiles()
                }
                .controlSize(.large)
                .frame(minHeight: 44)
            }

            if isWorking {
                VStack(spacing: 10) {
                    ProgressView("正在安全读取并解析…")
                    Button("取消", role: .cancel) { loadTask?.cancel() }
                }
            }
            Spacer()
        }
        .padding(24)
    }

    @ViewBuilder
    private var previewView: some View {
        if let preview {
            if usesWidePreview {
                HStack(spacing: 0) {
                    importSummary(preview)
                        .frame(width: 250)
                        .padding(20)
                        .background(Color.appSurface)
                    Divider()
                    candidateList(preview)
                }
            } else {
                candidateList(preview)
                    .safeAreaInset(edge: .bottom) {
                        compactImportSummary(preview)
                    }
            }
        } else {
            ProgressView()
        }
    }

    private func candidateList(_ preview: SessionImportPreview) -> some View {
        List {
            if !preview.warnings.isEmpty {
                Section("文件提示") {
                    ForEach(preview.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("找到 \(preview.candidates.count) 个会话") {
                ForEach(preview.candidates) { candidate in
                    SessionImportCandidateRow(
                        candidate: candidate,
                        isSelected: selectedIDs.contains(candidate.id),
                        importsDuplicate: duplicateOverrideIDs.contains(candidate.id),
                        identities: identities,
                        mappedIdentityID: identityMappingIDs[candidate.id],
                        onToggle: { selected in toggle(candidate, selected: selected) },
                        onImportDuplicate: { importDuplicate(candidate) },
                        onIdentityChange: { identityID in
                            identityMappingIDs[candidate.id] = identityID
                        }
                    )
                }
            }
            if preview.passwordCount > 0 {
                Section("凭据") {
                    Toggle("导入 \(preview.passwordCount) 个检测到的明文密码", isOn: $importPlaintextPasswords)
                    Text("默认关闭。开启后密码只写入本设备 Keychain，界面和日志不会显示密码。")
                        .font(.caption).foregroundStyle(.secondary)
                    if !identityMappingIDs.isEmpty {
                        Text("已映射共享身份的会话使用该身份的凭据，不会覆盖身份密码。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
#if os(iOS)
            if preview.candidates.contains(where: {
                $0.record.authentication == .privateKey || $0.record.authentication == .keyThenPassword
            }) {
                Section("iPhone 与 iPad 私钥") {
                    Text("移动端不会保留外部密钥路径。请选择上方已有共享身份；如果尚未导入密钥，可先在“更多 → SSH 密钥”通过系统文件选择器导入，然后重新执行会话导入。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
#endif
        }
    }

    private func importSummary(_ preview: SessionImportPreview) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("导入摘要", systemImage: "checklist")
                .font(.headline)
            summaryRow(
                "来源",
                preview.detectedSources.isEmpty
                    ? preview.requestedSource.title
                    : preview.detectedSources.map(\.title).joined(separator: "、")
            )
            summaryRow("有效", "\(preview.validCount)")
            summaryRow("重复", "\(preview.duplicateCount)")
            summaryRow("已选择", "\(selectedImportCount)")
            if preview.passwordCount > 0 { summaryRow("检测到密码", "\(preview.passwordCount)（隐藏）") }
            if !identityMappingIDs.isEmpty { summaryRow("身份映射", "\(identityMappingIDs.count)") }
            Divider()
            Label("重复项默认跳过，不会覆盖现有会话。", systemImage: "shield.checkered")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func compactImportSummary(_ preview: SessionImportPreview) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("已选择 \(selectedImportCount) 个会话").font(.headline)
                Text("\(preview.duplicateCount) 个重复项默认跳过").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(.regularMaterial)
    }

    private func summaryRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.medium))
        }
    }

    private var resultView: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 58)).foregroundStyle(Color.appLive)
            Text("会话已导入").font(.title2.bold())
            if let result {
                Text("成功导入 \(result.importedCount) 个会话，跳过 \(result.skippedCount) 个。")
                    .foregroundStyle(.secondary)
                if result.passwordCount > 0 {
                    Label("\(result.passwordCount) 个密码已保存到本设备 Keychain", systemImage: "lock.fill")
                        .font(.callout)
                }
            }
            Button("完成") { dismiss() }.buttonStyle(.borderedProminent).controlSize(.large)
            Spacer()
        }
        .padding()
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            if step == .source || step == .result {
                Button(step == .result ? "完成" : "取消") { dismiss() }
            } else {
                Button("返回") { goBack() }.disabled(isWorking)
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            switch step {
            case .source:
                Button("继续") { step = .input }
            case .preview:
                Button("确定（\(selectedImportCount)）", action: commit)
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedImportCount == 0 || isWorking)
            case .input, .result:
                EmptyView()
            }
        }
    }

    private var usesWidePreview: Bool {
#if os(macOS)
        true
#else
        horizontalSizeClass == .regular
#endif
    }

    private var selectedImportCount: Int {
        guard let preview else { return 0 }
        return preview.candidates.count { candidate in
            selectedIDs.contains(candidate.id)
                && candidate.isValid
                && (!candidate.isDuplicate || duplicateOverrideIDs.contains(candidate.id))
        }
    }

    private func toggle(_ candidate: SessionImportCandidate, selected: Bool) {
        if selected {
            if candidate.isDuplicate, !duplicateOverrideIDs.contains(candidate.id) { return }
            selectedIDs.insert(candidate.id)
        } else {
            selectedIDs.remove(candidate.id)
            duplicateOverrideIDs.remove(candidate.id)
        }
    }

    private func importDuplicate(_ candidate: SessionImportCandidate) {
        duplicateOverrideIDs.insert(candidate.id)
        selectedIDs.insert(candidate.id)
    }

    private func goBack() {
        switch step {
        case .input: step = .source
        case .preview:
            preview?.candidates.forEach { $0.credential?.clear() }
            preview = nil
            selectedIDs = []
            duplicateOverrideIDs = []
            identityMappingIDs = [:]
            importPlaintextPasswords = false
            step = .input
        case .source, .result: break
        }
    }

    private func handleFileSelection(_ selection: Result<[URL], Error>) {
        switch selection {
        case .success(let urls): inspect(.urls(urls))
        case .failure(let error):
            let cocoaError = error as NSError
            guard !(cocoaError.domain == NSCocoaErrorDomain && cocoaError.code == NSUserCancelledError) else {
                return
            }
            errorMessage = error.localizedDescription
        }
    }

    private func inspectDiscoveredFiles() {
        let urls = SessionLocalDiscovery.urls(for: source)
        guard !urls.isEmpty else {
            errorMessage = "没有在已知位置找到配置，请手动选择文件或目录。"
            return
        }
        inspect(.urls(urls))
    }

    private func inspect(_ input: SessionImportInput) {
        loadTask?.cancel()
        isWorking = true
        let keys = existingServers.map(ExistingSessionKey.init(server:))
        let requestedSource = source
        loadTask = Task {
            defer { isWorking = false }
            do {
                let value = try await SessionMigrationService.shared.preview(
                    source: requestedSource, input: input, existing: keys
                )
                guard !Task.isCancelled else { return }
                preview = value
                selectedIDs = Set(value.candidates.filter { $0.isValid && !$0.isDuplicate }.map(\.id))
                duplicateOverrideIDs = []
                identityMappingIDs = [:]
                step = .preview
            } catch is CancellationError {
                // User cancellation is not an error.
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func commit() {
        guard let preview else { return }
        isWorking = true
        do {
            let value = try SessionImportCommitter.commit(
                SessionImportSelection(
                    preview: preview,
                    selectedIDs: selectedIDs,
                    duplicateOverrideIDs: duplicateOverrideIDs,
                    identityMappingIDs: identityMappingIDs
                ),
                importPlaintextPasswords: importPlaintextPasswords,
                existingServers: existingServers,
                existingIdentities: identities,
                context: modelContext
            )
            result = value
            self.preview = nil
            onComplete?(value)
            step = .result
        } catch {
            errorMessage = error.localizedDescription
        }
        isWorking = false
    }
}

private struct SessionImportCandidateRow: View {
    let candidate: SessionImportCandidate
    let isSelected: Bool
    let importsDuplicate: Bool
    let identities: [IdentityRecord]
    let mappedIdentityID: UUID?
    let onToggle: (Bool) -> Void
    let onImportDuplicate: () -> Void
    let onIdentityChange: (UUID?) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: Binding(get: { isSelected }, set: onToggle))
                .labelsHidden()
                .disabled(!candidate.isValid || candidate.isDuplicate && !importsDuplicate)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(candidate.record.name).font(.headline).lineLimit(1)
                    Spacer()
                    Text(candidate.source.title).font(.caption2).foregroundStyle(.secondary)
                }
                Text("\(candidate.record.username)@\(candidate.record.host):\(candidate.record.port)")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 10) {
                    Label(candidate.record.group ?? "默认分组", systemImage: "folder")
                    Label(candidate.record.authentication.title, systemImage: "person.badge.key")
                }
                .font(.caption2).foregroundStyle(.secondary)
                Label(candidate.credentialStatus, systemImage: candidate.hasPlaintextPassword ? "lock.fill" : "key")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach(candidate.errors, id: \.self) { message in
                    Label(message, systemImage: "xmark.octagon.fill")
                        .font(.caption).foregroundStyle(Color.appError)
                }
                ForEach(candidate.warnings, id: \.self) { message in
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                if !identities.isEmpty {
                    Picker("使用已有身份", selection: Binding(
                        get: { mappedIdentityID },
                        set: onIdentityChange
                    )) {
                        Text("不映射").tag(UUID?.none)
                        ForEach(identities) { identity in
                            Text("\(identity.name) · \(identity.authentication.title)")
                                .tag(UUID?.some(identity.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(!candidate.isValid)
                }
                if candidate.isDuplicate && !importsDuplicate {
                    Button("导入副本", action: onImportDuplicate)
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.appAccent)
                } else if importsDuplicate {
                    Label("将作为副本导入", systemImage: "plus.square.on.square")
                        .font(.caption).foregroundStyle(Color.appAccent)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct SessionExportWizard: View {
    @Environment(\.dismiss) private var dismiss
    let servers: [ServerRecord]

    @State private var scope: SessionExportScope = .all
    @State private var group = ""
    @State private var selectedIDs = Set<UUID>()
    @State private var target: SessionTransferTarget = .serverDash
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var exportDocument: SessionExportFileDocument?
    @State private var exportType: UTType = .data
    @State private var exportName = "ServerDash-Sessions.json"
    @State private var showingExporter = false
    @State private var completionMessage: String?
    @State private var pendingExportWarnings: [String] = []
    @State private var exportTask: Task<Void, Never>?

    private var groups: [String] {
        Array(Set(servers.map(\.groupName))).sorted()
    }

    private var chosenServers: [ServerRecord] {
        switch scope {
        case .all: servers
        case .group: servers.filter { $0.groupName == group }
        case .selected: servers.filter { selectedIDs.contains($0.id) }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("范围") {
                    Picker("导出范围", selection: $scope) {
                        ForEach(SessionExportScope.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if scope == .group {
                        Picker("分组", selection: $group) {
                            ForEach(groups, id: \.self) { Text($0).tag($0) }
                        }
                    } else if scope == .selected {
                        ForEach(servers) { server in
                            Toggle(isOn: Binding(
                                get: { selectedIDs.contains(server.id) },
                                set: { selected in
                                    if selected { selectedIDs.insert(server.id) }
                                    else { selectedIDs.remove(server.id) }
                                }
                            )) {
                                VStack(alignment: .leading) {
                                    Text(server.displayName)
                                    Text("\(server.username)@\(server.host):\(server.port)")
                                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    LabeledContent("将导出", value: "\(chosenServers.count) 个会话")
                }

                Section("目标客户端") {
                    ForEach(SessionTransferTarget.allCases) { item in
                        Button {
                            target = item
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.title).foregroundStyle(.primary)
                                    Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if item.exportAvailability != .available {
                                    Text("待验证").font(.caption).foregroundStyle(.orange)
                                } else if target == item {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.appAccent)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(item.exportAvailability != .available)
                    }
                }

                Section("安全") {
                    Label("导出不包含密码、私钥正文、口令、可信主机、历史记录或隧道。", systemImage: "lock.shield")
                    Text("外部私钥路径可以保留；存放在 Keychain 的密钥需要在目标客户端重新导入。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if isWorking {
                    Section { ProgressView("正在生成导出文件…") }
                }
            }
            .navigationTitle("导出会话")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isWorking ? "停止" : "取消") {
                        if isWorking {
                            exportTask?.cancel()
                        } else {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导出", action: prepareExport)
                        .buttonStyle(.borderedProminent)
                        .disabled(chosenServers.isEmpty || isWorking || target.exportAvailability != .available)
                }
            }
        }
        .sessionWizardFrame()
        .interactiveDismissDisabled(isWorking)
        .onAppear {
            if group.isEmpty { group = groups.first ?? "" }
            selectedIDs = Set(servers.map(\.id))
        }
        .onDisappear { exportTask?.cancel() }
        .fileExporter(
            isPresented: $showingExporter,
            document: exportDocument,
            contentType: exportType,
            defaultFilename: exportName
        ) { result in
            switch result {
            case .success:
                var messages = ["已导出 \(chosenServers.count) 个会话。密码和私钥正文未写入文件。"]
                messages.append(contentsOf: pendingExportWarnings)
                completionMessage = messages.joined(separator: "\n")
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
            exportDocument = nil
            pendingExportWarnings = []
        }
        .alert("导出失败", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("好", role: .cancel) {} } message: { Text(errorMessage ?? "") }
        .alert("导出完成", isPresented: Binding(
            get: { completionMessage != nil }, set: { if !$0 { completionMessage = nil } }
        )) {
            Button("完成") { dismiss() }
        } message: {
            Text(completionMessage ?? "")
        }
    }

    private func prepareExport() {
        exportTask?.cancel()
        let records = chosenServers.map(SessionTransferRecord.init(server:))
        let selectedTarget = target
        isWorking = true
        exportTask = Task {
            defer { isWorking = false }
            do {
                let artifact = try await SessionMigrationService.shared.export(records: records, target: selectedTarget)
                try Task.checkCancellation()
                exportDocument = SessionExportFileDocument(data: artifact.data)
                exportType = UTType(filenameExtension: selectedTarget.suggestedExtension) ?? .data
                exportName = artifact.suggestedFileName
                pendingExportWarnings = artifact.warnings
                showingExporter = true
            } catch is CancellationError {
                // Explicit cancellation leaves the wizard ready for another export.
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct SessionExportFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private extension View {
    @ViewBuilder
    func sessionWizardFrame() -> some View {
#if os(macOS)
        frame(minWidth: 760, idealWidth: 900, minHeight: 600, idealHeight: 720)
#else
        self
#endif
    }
}

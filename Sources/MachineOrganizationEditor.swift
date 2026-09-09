import SwiftData
import SwiftUI

struct MachineOrganizationEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \MachineGroupRecord.name) private var groups: [MachineGroupRecord]
    @Query(sort: \MachineTagRecord.name) private var tags: [MachineTagRecord]
    let machines: [WorkbenchMachine]
    @State private var section = 0
    @State private var selectedID: UUID?
    @State private var name = ""
    @State private var parent: UUID?
    @State private var colorName = MachineTagTint.accent.rawValue
    @State private var error: String?
    @State private var deleting = false
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("管理分组与标签").font(.title2.weight(.semibold)); Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.cancelAction) }.padding(20)
            Divider()
            HSplitView {
                VStack {
                    Picker("类别", selection: $section) { Text("分组").tag(0); Text("标签").tag(1) }.pickerStyle(.segmented)
                    List(selection: $selectedID) {
                        if section == 0 { ForEach(groups) { Label($0.name, systemImage: "folder").tag($0.id) } }
                        else { ForEach(tags) { Label($0.name, systemImage: "tag").foregroundStyle((MachineTagTint(rawValue: $0.colorName) ?? .accent).color).tag($0.id) } }
                    }
                    HStack {
                        Button("新建", systemImage: "plus") { selectedID = nil; name = ""; parent = nil; colorName = MachineTagTint.accent.rawValue; error = nil }
                        Button("删除", systemImage: "minus", role: .destructive) { deleting = true }.disabled(selectedID == nil)
                        Spacer()
                    }
                }.padding(12).frame(minWidth: 170, idealWidth: 200)
                Form {
                    Section(selectedID == nil ? "新建" : "编辑") {
                        TextField("名称", text: $name)
                        if section == 0 {
                            Picker("父分组", selection: $parent) {
                                Text("顶层").tag(UUID?.none)
                                ForEach(groups.filter { candidate in
                                    guard let selectedID, let current = groups.first(where: { $0.id == selectedID }) else { return true }
                                    return MachineOrganization.canMove(current, under: candidate.id, groups: groups)
                                }) { Text($0.name).tag(Optional($0.id)) }
                            }
                        } else {
                            Picker("颜色", selection: $colorName) {
                                ForEach(MachineTagTint.allCases) { color in Label(color.title, systemImage: "circle.fill").foregroundStyle(color.color).tag(color.rawValue) }
                            }
                        }
                        Button("保存", action: save).buttonStyle(.borderedProminent).disabled(MachineOrganization.cleanName(name).isEmpty)
                    }
                    if let error { Text(error).foregroundStyle(Color.appError) }
                    Text(section == 0 ? "删除分组会将主机移到默认分组；子分组提升到原父级。名称同步到现有主机配置。" : "重命名会更新主机标签；删除标签不会删除主机。").font(.caption).foregroundStyle(.secondary)
                }.formStyle(.grouped).frame(minWidth: 300)
            }
        }.frame(width: 660, height: 470).background(Color.appGround)
            .onChange(of: selectedID) { _, _ in load() }
            .onChange(of: section) { _, _ in selectedID = nil; name = ""; parent = nil; colorName = MachineTagTint.accent.rawValue; error = nil }
            .confirmationDialog("删除\(section == 0 ? "分组" : "标签")？", isPresented: $deleting) {
                Button("删除", role: .destructive, action: remove)
            }
    }
    private func load() {
        error = nil
        if section == 0, let item = groups.first(where: { $0.id == selectedID }) { name = item.name; parent = item.parentID }
        else if let item = tags.first(where: { $0.id == selectedID }) { name = item.name; colorName = item.colorName }
    }
    private func save() {
        let clean = MachineOrganization.cleanName(name)
        guard !clean.isEmpty else { return }
        error = nil
        if section == 0 {
            guard !groups.contains(where: { $0.name.localizedCaseInsensitiveCompare(clean) == .orderedSame && $0.id != selectedID }) else { error = "已存在同名分组。"; return }
            if let item = groups.first(where: { $0.id == selectedID }) {
                guard MachineOrganization.canMove(item, under: parent, groups: groups) else { error = "不能将分组移入自身或子分组。"; return }
                let old = item.name
                for machine in machines where machine.group == old { machine.setGroup(clean) }
                item.name = clean; item.parentID = parent
            } else { let item = MachineGroupRecord(name: clean, parentID: parent); context.insert(item); selectedID = item.id }
        } else {
            guard !clean.contains(where: { ",，;；".contains($0) }) else {
                error = "标签名称不能包含逗号或分号。"; return
            }
            guard !tags.contains(where: { $0.name.localizedCaseInsensitiveCompare(clean) == .orderedSame && $0.id != selectedID }) else { error = "已存在同名标签。"; return }
            if let item = tags.first(where: { $0.id == selectedID }) {
                let old = item.name
                for machine in machines where machine.tags.contains(old) { machine.setTags(machine.tags.map { $0 == old ? clean : $0 }) }
                item.name = clean; item.colorName = colorName
            } else { let item = MachineTagRecord(name: clean, colorName: colorName); context.insert(item); selectedID = item.id }
        }
        do { try context.save() } catch { self.error = error.localizedDescription }
    }
    private func remove() {
        if section == 0, let item = groups.first(where: { $0.id == selectedID }) {
            for machine in machines where machine.group == item.name { machine.setGroup("默认分组") }
            for child in groups where child.parentID == item.id { child.parentID = item.parentID }
            context.delete(item)
        } else if let item = tags.first(where: { $0.id == selectedID }) {
            for machine in machines { machine.setTags(machine.tags.filter { $0 != item.name }) }
            context.delete(item)
        }
        do { try context.save(); selectedID = nil; name = ""; parent = nil } catch { self.error = error.localizedDescription }
    }
}

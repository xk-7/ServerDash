// Appended after exact source excerpts by generate.py. Fixed UUID/date/nonce make the
// content reproducible. Recording JSON key order and LZFSE block sizes may vary.
// The recovery key is public test data, never a user credential.
func fixtureID(_ suffix: String) -> UUID { UUID(uuidString: "12345678-90AB-CDEF-1234-" + suffix)! }
let fixtureKey = Data(0..<32)
let fixtureDate = Date(timeIntervalSince1970: 1_783_468_800)
func fixtureJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
}
func writeJSON(_ value: Any, _ name: String, _ directory: URL) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: directory.appendingPathComponent(name))
}
func fixtureFrame() -> RecordingFrame {
    let line = TerminalDisplaySnapshot.Line(cells: [
        .init(text: "中", width: 2, foreground: 0x112233, background: 0, style: 1),
        .init(text: "", width: 0, foreground: 0x112233, background: 0, style: 0),
        .init(text: "e\u{301}", width: 1, foreground: 0xffffff, background: 0x102030, style: 4, underline: 0xff0000),
        .init(text: "👩🏽‍💻", width: 2, foreground: 0xabcdef, background: 0, style: 0),
        .init(text: "", width: 0, foreground: 0xabcdef, background: 0, style: 0)
    ], mode: 0)
    return RecordingFrame(screen: .init(columns: 5, rows: 1, lines: [line], cursorColumn: 5, cursorRow: 0,
        cursorVisible: true, cursorStyle: "steadyBlock", foreground: 0xffffff, background: 0, hasImages: false),
        appearance: .init(fontName: "Menlo", fontSize: 12, cellWidth: 7, cellHeight: 15))
}
func fixtureObjects() throws -> [SyncConfigurationObject] {
    let host = fixtureID("000000000001")
    let route = ConnectionRoute(id: fixtureID("000000000006"), revision: fixtureID("000000000016"), name: "跳板",
        hops: [.init(id: fixtureID("000000000026"), name: "jump", endpoint: .init(host: "jump.example", port: 22, username: "ops"), credential: .sshAgent)],
        proxy: .init(kind: .socks5, host: "proxy.example", port: 1080))
    return [
        .init(id: host, kind: "ssh", fields: ["name":"示例主机", "host":"linux.example", "port":"2222", "username":"ops", "authentication":"privateKey", "group":"研发", "tags":"开发,测试", "notes":"path /srv/a=b", "sftpPath":"/srv"]),
        .init(id: fixtureID("000000000002"), kind: "group", fields: ["name":"研发"]),
        .init(id: fixtureID("000000000003"), kind: "tag", fields: ["name":"开发", "color":"blue"]),
        .init(id: fixtureID("000000000004"), kind: "rdp", fields: ["name":"Windows", "host":"windows.example", "port":"3389", "username":"operator", "domain":"EXAMPLE", "group":"研发", "tags":"", "notes":"", "settings":String(decoding: try fixtureJSON(RDPSettings()), as: UTF8.self)]),
        .init(id: fixtureID("000000000005"), kind: "advanced", fields: ["server":host.uuidString, "settings":String(decoding: try fixtureJSON(SSHAdvancedSettingsDraft.default), as: UTF8.self)]),
        .init(id: route.id, kind: "route", fields: ["server":host.uuidString, "route":String(decoding: try fixtureJSON(route), as: UTF8.self)]),
        .init(id: fixtureID("000000000007"), kind: "vnc", fields: ["name":"VNC", "host":"vnc.example", "port":"5900", "group":"研发", "tags":"", "notes":""]),
        .init(id: fixtureID("000000000008"), kind: "serial", fields: ["name":"串口", "baud":"115200", "bits":"8", "parity":"none", "stop":"1", "flow":"none", "group":"研发", "tags":"", "notes":""]),
        .init(id: fixtureID("000000000009"), kind: "tunnel", fields: ["server":host.uuidString, "name":"db", "direction":"local", "bind":"127.0.0.1", "port":"15432", "target":"127.0.0.1", "targetPort":"5432"]),
        .init(id: fixtureID("00000000000A"), kind: "tag", fields: ["name":"已删除", "color":"gray"], deleted: true)
    ]
}
func generateFixtures(_ directory: URL) throws {
    let sourceID = fixtureID("000000000099")
    let local = LocalConfigurationPackage(sourceID: sourceID, objects: try fixtureObjects())
    try local.encoded().write(to: directory.appendingPathComponent("swift-local.json"))
    let package = ConfigurationSyncPackage(spaceID: local.mappingSpaceID, objects: local.objects)
    let header = Data("ServerDash.ConfigSync.v1\n".utf8)
    let nonce = try AES.GCM.Nonce(data: Data(160..<172))
    let box = try AES.GCM.seal(fixtureJSON(package), using: SymmetricKey(data: fixtureKey), nonce: nonce, authenticating: header)
    let encrypted = header + box.combined!
    let decrypted = try ConfigurationSyncCrypto.decrypt(encrypted, key: fixtureKey); precondition(decrypted == package)
    try encrypted.write(to: directory.appendingPathComponent("swift-sync.configsync"))
    let frame = fixtureFrame(); try frame.validate()
    try fixtureJSON(frame).write(to: directory.appendingPathComponent("swift-frame.json"))
    let recordHeader = RecordingHeader(id: fixtureID("000000000088"), name: "中文 / recording", date: fixtureDate)
    let first = RecordingEvent(kind: .header, time: 0, header: recordHeader)
    var bytes = RecordingCodec.magic + (try RecordingCodec.encode(first))
    let offset = UInt64(bytes.count)
    bytes += try RecordingCodec.encode(.init(kind: .screen, time: 0, frame: frame))
    bytes += try RecordingCodec.encode(.init(kind: .output, time: 0.5, output: Data("\u{1b}]52;c;bm90LWV4ZWN1dGVk\u{7}".utf8)))
    var delta = frame; delta.changedRows = [0]; delta.screen.lines[0].cells[0].text = "文"
    bytes += try RecordingCodec.encode(.init(kind: .screen, time: 1, frame: delta))
    try (bytes + Data([3, 1])).write(to: directory.appendingPathComponent("swift-recording.partial"))
    bytes += try RecordingCodec.encode(.init(kind: .end, time: 2, index: [.init(time: 0, offset: offset)], reason: "user"))
    let recordingURL = directory.appendingPathComponent("swift-recording.sdrec")
    try bytes.write(to: recordingURL)
    let document = try RecordingDocument.open(recordingURL)
    precondition(document.complete && document.duration == 2)
    try writeJSON(["sourceID":sourceID.uuidString,"mappingSpaceID":local.mappingSpaceID.uuidString,"recoveryKeyHex":fixtureKey.map { String(format:"%02x",$0) }.joined(),"recordingDate":fixtureDate.timeIntervalSinceReferenceDate,"recordingUnixDate":fixtureDate.timeIntervalSince1970,"recordingKeyframeOffset":offset], "swift-metadata.json", directory)
    var streams: [[String: Any]] = []
    for provider in AIProviderID.allCases {
        let wire: String
        switch provider {
        case .anthropic: wire = "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"你好\"}}\n\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n\ndata: {\"type\":\"message_stop\"}\n\n"
        case .gemini: wire = "data: {\"candidates\":[{\"index\":0,\"content\":{\"parts\":[{\"text\":\"hidden\",\"thought\":true},{\"text\":\"你好\"}]},\"finishReason\":\"STOP\"}]}\n\n"
        case .ollama: wire = "{\"message\":{\"content\":\"你好\",\"thinking\":\"hidden\"},\"done\":true,\"done_reason\":\"stop\"}\n"
        default: wire = "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"你好\",\"reasoning_content\":\"hidden\"},\"finish_reason\":null}]}\r\n\r\ndata: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
        }
        var decoder = AIProviderStreamDecoder(provider: provider); var output = ""; var finish = ""
        let emit: (AIStreamEvent) -> Void = { event in switch event { case .text(let text): output += text; case .finished(let reason): finish = String(describing: reason) } }
        for byte in wire.utf8 { try decoder.receive(Data([byte]), emit: emit) }
        try decoder.validateEnd(emit: emit)
        var profile = AIProviderProfile(provider: provider); profile.model = "fixture-model"
        let request = try AIProviderAdapter(provider: provider).request(profile: profile, key: "fixture-only-not-a-real-key", messages: [.init(role:"system", content:"Help"),.init(role:"user",content:"Hello")])
        streams.append(["provider":provider.rawValue,"wire":wire,"text":output,"finish":finish,"url":request.url!.absoluteString,"body":try JSONSerialization.jsonObject(with:request.httpBody!)])
    }
    try writeJSON(streams, "swift-ai.json", directory)
    let session = ServerDashSessionDocument(exportedAt: fixtureDate, generator: .init(version:"fixture"), sessions:[.init(name:"测试",group:"研发",host:"example.com",port:2222,username:"ops",authentication:.privateKey,externalPrivateKeyPath:"C:\\Users\\Example\\.ssh\\id_ed25519",notes:"no credential material",tags:["开发"],defaultRemotePath:"/srv")])
    let sessionEncoder = JSONEncoder(); sessionEncoder.outputFormatting = [.sortedKeys]; sessionEncoder.dateEncodingStrategy = .iso8601
    try sessionEncoder.encode(session).write(to: directory.appendingPathComponent("swift-sessions.json"))
    let monitor = """
    cpu=12.5
    cores=8
    load1=0.75
    load5=0.5
    load15=0.25
    mem_total_kb=8192
    mem_available_kb=4096
    mem_free_kb=1024
    mem_cached_kb=2048
    mem_buffers_kb=512
    swap_total_kb=2048
    swap_free_kb=1536
    disk_used=1234567
    disk_total=9999999
    net_rx=10123456
    net_tx=20123456
    active_iface=eth0
    iface=eth0|10123456|20123456
    proc=12|root|worker|2.5|1.25|4|worker --label=a=b|tail
    core=0|2|3|1|4|0
    fs=/dev/vda1|ext4|1234567|9999999|/srv/a|b
    gpu=0|GPU-example|GPU fixture|12|16|1024|N/A|42|N/A|100
    gproc=GPU-example|12|worker|16
    dcont=abcdef|service|example:1|running|Up 1 hour|healthy
    docker_available=1
    listener=tcp|0.0.0.0:22|sshd,pid=123
    listeners_available=true
    distro=Fixture Linux
    kernel=6.0-fixture
    uptime=1 day
    """ + "\n"
    let metrics = try MonitoringResponseParser.parse(monitor)
    try Data(monitor.utf8).write(to:directory.appendingPathComponent("monitoring.txt"))
    try writeJSON(["cpuPercent":metrics.cpuUsage,"memoryUsedBytes":metrics.memoryUsedBytes,"memoryTotalBytes":metrics.memoryTotalBytes,"memoryCachedBytes":metrics.memoryCachedBytes,"swapUsedBytes":metrics.swapUsedBytes,"processArguments":metrics.processes[0].arguments,"filesystemMount":metrics.filesystems[0].mountPoint,"gpuMemoryUsedBytes":metrics.gpus[0].memoryUsedBytes,"gpuFan":metrics.gpus[0].fanPercent as Any? ?? NSNull(),"dockerStatus":metrics.dockerContainers[0].status],"swift-monitoring.json",directory)
}
func verifyRustFixtures(_ directory: URL) throws {
    let local = try LocalConfigurationPackage.decode(Data(contentsOf:directory.appendingPathComponent("rust-local.json")))
    let expectedObjects = try fixtureObjects(); precondition(local.objects == expectedObjects)
    let package = try ConfigurationSyncCrypto.decrypt(Data(contentsOf:directory.appendingPathComponent("rust-sync.configsync")),key:fixtureKey)
    precondition(package.objects == local.objects && package.spaceID == local.mappingSpaceID)
    let document = try RecordingDocument.open(directory.appendingPathComponent("rust-recording.sdrec"))
    precondition(document.complete && document.duration == 2)
    let cursor = try RecordingCursor(document); let initialFrame = try cursor.seek(0); precondition(initialFrame == fixtureFrame())
    print("Swift verified Rust configuration encryption, local configuration and LZFSE recording")
}
func normalizedRecording(_ url: URL) throws -> Data {
    let document = try RecordingDocument.open(url, allowPartial: true)
    let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
    try file.seek(toOffset: 8)
    var events: [RecordingEvent] = []
    while try file.offset() < document.validEnd {
        guard var event = try RecordingCodec.read(file) else { throw RecordingError.invalid }
        // open() already verified the footer against actual block offsets. Compare
        // event times/content independently of JSON key order and compression size.
        event.index = event.index?.map { .init(time: $0.time, offset: 0) }
        events.append(event)
    }
    return try fixtureJSON(events)
}
let outputDirectory = URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true)
if CommandLine.arguments[1] == "verify-rust" { try verifyRustFixtures(outputDirectory) }
else if CommandLine.arguments[1] == "compare-recordings" {
    let other = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
    for name in ["swift-recording.sdrec", "swift-recording.partial"] {
        let actual = try normalizedRecording(outputDirectory.appendingPathComponent(name))
        let expected = try normalizedRecording(other.appendingPathComponent(name))
        precondition(actual == expected, "Recording fixture drift: \(name)")
    }
}
else { try generateFixtures(outputDirectory) }

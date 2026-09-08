import AppKit
import MetalKit
import SwiftUI

enum RDPScreenCatalog {
    struct Screen: Identifiable { let id: UInt32; let name: String; let screen: NSScreen }
    static var screens: [Screen] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { return nil }
            return Screen(id: id, name: screen.localizedName, screen: screen)
        }
    }
    static func layout(ids: [UInt32]) throws -> [RDPMonitor] {
        let selected = screens.filter { ids.contains($0.id) }
        guard selected.count == ids.count, let primary = selected.first else { throw RDPValidationError.invalidLayout }
        // Use one common logical pixel coordinate space, including mixed-DPI displays.
        let origin = primary.screen.frame
        let result = selected.map { value in
            RDPMonitor(screenID: value.id, x: Int(value.screen.frame.minX - origin.minX),
                y: Int(origin.maxY - value.screen.frame.maxY), width: Int(value.screen.frame.width),
                height: Int(value.screen.frame.height), primary: value.id == primary.id)
        }
        try RDPDisplayLayout.validate(result)
        return result
    }
}

struct RDPDesktopPane: View {
    @ObservedObject var controller: RDPSessionController
    @ObservedObject var clipboard: RDPClipboardSession
    @State private var password = ""
    init(controller: RDPSessionController) { self.controller = controller; self.clipboard = controller.clipboard }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Circle().fill(controller.state == .connected ? Color.green : Color.secondary).frame(width: 7, height: 7)
                Text(controller.configuration.name).font(.headline)
                Text(controller.state.rawValue).foregroundStyle(.secondary)
                Spacer()
                Menu("发送按键") {
                    Button("Alt+Tab") { controller.sendSpecial([0x38, 0x0F]) }
                    Button("Windows 键") { controller.sendSpecial([0x15B]) }
                    Button("Ctrl+Alt+Delete") { controller.sendSpecial([0x1D, 0x38, 0x153]) }
                    Button("释放键盘捕获") { controller.releaseKeys(); controller.keyboardCaptured = false }
                    Button("恢复键盘捕获") { controller.keyboardCaptured = true }
                }.disabled(controller.state != .connected)
                Button("全屏", systemImage: "arrow.up.left.and.arrow.down.right") { controller.openFullscreen() }
                    .disabled(controller.state != .connected)
                if controller.state == .connected || controller.state == .connecting || controller.state == .reconnecting {
                    Button("断开") { controller.disconnect() }
                } else { Button("重新连接") { controller.connect() } }
            }.padding(12).background(.bar)
            ZStack {
                Color.black
                RDPDesktopRepresentable(controller: controller, monitor: nil)
                if controller.frame == nil || controller.needsPassword {
                    VStack(spacing: 16) {
                        Image(systemName: "desktopcomputer").font(.system(size: 48)).foregroundStyle(.secondary)
                        Text(controller.message).multilineTextAlignment(.center)
                        if controller.needsPassword {
                            SecureField("Windows 密码", text: $password).textFieldStyle(.roundedBorder).frame(width: 260)
                            Button("连接") { controller.connect(password: password); password = "" }.buttonStyle(.borderedProminent)
                        } else if controller.state == .connecting { ProgressView() }
                    }.padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            HStack {
                Text(controller.message).lineLimit(2)
                Spacer()
                if let progress = clipboard.progress ?? clipboard.uploadProgress {
                    ProgressView(value: progress).frame(width: 100)
                    Button("取消传输") { clipboard.cancelTransfer() }
                }
                if let frame = controller.frame { Text("\(frame.width) × \(frame.height) · \(frame.colorDepth) 位").monospacedDigit() }
                if !clipboard.message.isEmpty { Text(clipboard.message).foregroundStyle(.orange) }
            }.font(.caption).padding(10).background(.bar)
        }
        .onAppear { controller.setVisible(true) }
        .onDisappear { controller.setVisible(false) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in controller.setVisible(false) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in controller.setVisible(true) }
        .alert(controller.trustPrompt?.previousFingerprint == nil ? "确认 RDP 证书" : "RDP 证书已变化",
               isPresented: Binding(get: { controller.trustPrompt != nil }, set: { _ in })) {
            Button("取消", role: .cancel) { controller.resolveTrust(accept: false) }
            Button("核对后信任") { controller.resolveTrust(accept: true) }
        } message: {
            if let prompt = controller.trustPrompt {
                Text("\(controller.configuration.host):\(controller.configuration.port)\n\(prompt.evidence.subject)\n旧指纹：\(prompt.previousFingerprint ?? "无")\nSHA-256：\(prompt.evidence.fingerprint)\n请通过可信渠道核对，确认后才会继续发送登录凭据。")
            }
        }
    }
}

struct RDPDesktopRepresentable: NSViewRepresentable {
    @ObservedObject var controller: RDPSessionController
    let monitor: RDPMonitor?
    func makeNSView(context: Context) -> RDPMetalView { RDPMetalView(controller: controller, monitor: monitor) }
    func updateNSView(_ view: RDPMetalView, context: Context) { view.setFrame(controller.frame) }
    static func dismantleNSView(_ view: RDPMetalView, coordinator: ()) { view.dismantle() }
}

@MainActor
final class RDPMetalView: MTKView, MTKViewDelegate, @preconcurrency NSTextInputClient {
    private weak var controller: RDPSessionController?
    private let monitor: RDPMonitor?
    private var lastFrame: RDPFrame?
    private var texture: MTLTexture?
    private var pipeline: MTLRenderPipelineState?
    private var commandQueue: MTLCommandQueue?
    private var marked = NSAttributedString(string: "")
    private var resizeTask: Task<Void, Never>?
    private var tracking: NSTrackingArea?
    private var pointerButtons: Set<UInt16> = []
    private var modifiers: NSEvent.ModifierFlags = []
    private var uploadingFrame: RDPFrame?
    private var gpuBusy = false
    private var uploadedSequence: UInt64?
    private var uploadedConnectionID: UUID?
    private let focusID = UUID()
    private var lastPointer = CGPoint.zero
    private var windowObservers: [NSObjectProtocol] = []
    init(controller: RDPSessionController, monitor: RDPMonitor?) {
        self.controller = controller; self.monitor = monitor
        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
        isPaused = true; enableSetNeedsDisplay = true; framebufferOnly = true
        clearColor = MTLClearColorMake(0, 0, 0, 1); colorPixelFormat = .bgra8Unorm
        delegate = self
        commandQueue = device?.makeCommandQueue()
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct V { float4 position [[position]]; float2 uv; };
        vertex V vtx(uint id [[vertex_id]], constant float4 &crop [[buffer(0)]]) {
            const float2 p[4] = {float2(-1,1),float2(-1,-1),float2(1,1),float2(1,-1)};
            const float2 uv[4] = {float2(0,0),float2(0,1),float2(1,0),float2(1,1)};
            return {float4(p[id],0,1),crop.xy+uv[id]*crop.zw};
        }
        fragment float4 frag(V in [[stage_in]], texture2d<float> image [[texture(0)]]) {
            constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
            return float4(image.sample(s,in.uv).rgb,1);
        }
        """
        do {
            let library = try device?.makeLibrary(source: source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library?.makeFunction(name: "vtx")
            descriptor.fragmentFunction = library?.makeFunction(name: "frag")
            descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
            pipeline = try device?.makeRenderPipelineState(descriptor: descriptor)
        } catch { setAccessibilityHelp("Metal 桌面渲染不可用。") }
        setAccessibilityLabel("RDP 远程桌面"); setAccessibilityRole(.group)
        setAccessibilityHelp("远程桌面像素内容不提供本地 VoiceOver 语义。工具栏可以用键盘操作。")
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver); windowObservers = []
        guard let window else { return }
        windowObservers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.window?.firstResponder === self else { return }
                self.controller?.setInputFocus(self.focusID, focused: true)
            }
        })
        windowObservers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }; self.releaseInput(); self.controller?.setInputFocus(self.focusID, focused: false)
            }
        })
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
        super.updateTrackingAreas()
    }
    func setFrame(_ value: RDPFrame?) {
        guard let value, value.connectionID != lastFrame?.connectionID || value.sequence != lastFrame?.sequence || value.sequence == 0 else { return }
        uploadingFrame = value
        lastFrame = value
        needsDisplay = true
    }
    private func upload(_ value: RDPFrame) {
        var region = value.dirtyRect
        if texture?.width != value.width || texture?.height != value.height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: value.width, height: value.height, mipmapped: false)
            descriptor.usage = .shaderRead; descriptor.storageMode = .shared
            texture = device?.makeTexture(descriptor: descriptor)
            uploadedSequence = nil
        }
        // If rendering skipped intermediate frames, their dirty rectangles must not be lost.
        if uploadedConnectionID != value.connectionID || (uploadedSequence.map({ $0 &+ 1 != value.sequence }) ?? true) {
            region = CGRect(x: 0, y: 0, width: value.width, height: value.height)
        }
        let x = Int(region.minX), y = Int(region.minY), width = Int(region.width), height = Int(region.height)
        guard width > 0, height > 0, x >= 0, y >= 0, x + width <= value.width, y + height <= value.height else { return }
        value.pixels.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress { texture?.replace(region: MTLRegionMake2D(x, y, width, height), mipmapLevel: 0,
                withBytes: base.advanced(by: (y * value.width + x) * 4), bytesPerRow: value.width * 4) }
        }
        uploadedSequence = value.sequence; uploadedConnectionID = value.connectionID
    }
    private var cropRect: CGRect {
        guard let frame = lastFrame else { return .zero }
        guard let monitor, let controller, let monitors = try? RDPScreenCatalog.layout(ids: controller.configuration.settings.screenIDs),
              let minX = monitors.map(\.x).min(), let minY = monitors.map(\.y).min() else {
            return CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
        }
        return CGRect(x: monitor.x - minX, y: monitor.y - minY, width: monitor.width, height: monitor.height)
            .intersection(CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
    }
    private var contentRect: CGRect {
        let crop = cropRect
        guard crop.width > 0, crop.height > 0 else { return .zero }
        let scale = min(bounds.width / crop.width, bounds.height / crop.height)
        return CGRect(x: (bounds.width - crop.width * scale) / 2, y: (bounds.height - crop.height * scale) / 2,
            width: crop.width * scale, height: crop.height * scale)
    }
    func draw(in view: MTKView) {
        guard !gpuBusy else { return }
        if let pending = uploadingFrame { upload(pending); uploadingFrame = nil }
        guard let frame = lastFrame, let texture, let pipeline, let descriptor = currentRenderPassDescriptor,
              let drawable = currentDrawable, let command = commandQueue?.makeCommandBuffer(),
              let encoder = command.makeRenderCommandEncoder(descriptor: descriptor), bounds.width > 0, bounds.height > 0 else { return }
        let rect = contentRect, crop = cropRect
        let scaleX = drawableSize.width / bounds.width, scaleY = drawableSize.height / bounds.height
        encoder.setViewport(MTLViewport(originX: rect.minX * scaleX, originY: rect.minY * scaleY,
            width: rect.width * scaleX, height: rect.height * scaleY, znear: 0, zfar: 1))
        var region = SIMD4<Float>(Float(crop.minX) / Float(frame.width), Float(crop.minY) / Float(frame.height),
            Float(crop.width) / Float(frame.width), Float(crop.height) / Float(frame.height))
        encoder.setVertexBytes(&region, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        encoder.setRenderPipelineState(pipeline); encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding(); command.present(drawable)
        gpuBusy = true
        command.addCompletedHandler { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }; self.gpuBusy = false
                if self.uploadingFrame != nil { self.needsDisplay = true }
            }
        }
        command.commit()
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        guard monitor == nil, controller?.showingFullscreen != true,
              controller?.configuration.settings.dynamicResolution == true else { return }
        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard let self else { return }
            let width = min(8192, max(200, Int(size.width) / 2 * 2)), height = min(8192, max(200, Int(size.height)))
            self.controller?.resize([RDPMonitor(screenID: 0, x: 0, y: 0, width: width, height: height, primary: true)])
        }
    }
    private func pointer(_ event: NSEvent, flags: UInt16) {
        let point = convert(event.locationInWindow, from: nil), rect = contentRect, crop = cropRect
        guard rect.width > 0, rect.height > 0 else { return }
        if rect.contains(point) {
            lastPointer = CGPoint(x: crop.minX + (point.x - rect.minX) / rect.width * crop.width,
                                  y: crop.minY + (point.y - rect.minY) / rect.height * crop.height)
        } else if flags != 0x1000 && flags != 0x2000 { return }
        controller?.pointer(flags: flags, x: Int(lastPointer.x), y: Int(lastPointer.y))
    }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); pointerButtons.insert(0x1000); pointer(event, flags: 0x9000) }
    override func mouseUp(with event: NSEvent) { pointerButtons.remove(0x1000); pointer(event, flags: 0x1000) }
    override func rightMouseDown(with event: NSEvent) { pointerButtons.insert(0x2000); pointer(event, flags: 0xA000) }
    override func rightMouseUp(with event: NSEvent) { pointerButtons.remove(0x2000); pointer(event, flags: 0x2000) }
    override func mouseMoved(with event: NSEvent) { pointer(event, flags: 0x0800) }
    override func mouseDragged(with event: NSEvent) { pointer(event, flags: 0x0800) }
    override func rightMouseDragged(with event: NSEvent) { pointer(event, flags: 0x0800) }
    override func scrollWheel(with event: NSEvent) {
        if event.scrollingDeltaY != 0 { pointer(event, flags: event.scrollingDeltaY > 0 ? 0x0278 : 0x0388) }
        if event.scrollingDeltaX != 0 { pointer(event, flags: event.scrollingDeltaX > 0 ? 0x0478 : 0x0588) }
    }
    private var remoteShortcuts: Bool {
        guard let controller, controller.keyboardCaptured else { return false }
        switch controller.configuration.settings.keyboardMode {
        case .remote: return true
        case .local: return false
        case .fullscreen: return controller.showingFullscreen
        }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 && event.modifierFlags.intersection([.control, .option, .shift]) == [.control, .option, .shift] {
            releaseInput(); controller?.keyboardCaptured = false; return
        }
        guard controller?.keyboardCaptured == true else { super.keyDown(with: event); return }
        let systemShortcut = event.modifierFlags.contains(.command) ||
            (event.keyCode == 48 && !event.modifierFlags.intersection([.option, .control]).isEmpty)
        if systemShortcut, !remoteShortcuts { controller?.releaseKeys(); super.keyDown(with: event); return }
        if let code = Self.specialKeys[event.keyCode] { controller?.sendKey(code, down: true) }
        else if event.modifierFlags.intersection([.control, .command]).isEmpty { interpretKeyEvents([event]) }
        else if let code = Self.physicalKeys[event.keyCode] { controller?.sendKey(code, down: true) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard remoteShortcuts, window?.isKeyWindow == true, window?.firstResponder === self,
              !event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            return super.performKeyEquivalent(with: event)
        }
        keyDown(with: event)
        return true
    }
    override func keyUp(with event: NSEvent) {
        if let code = Self.specialKeys[event.keyCode] ?? Self.physicalKeys[event.keyCode] { controller?.sendKey(code, down: false) }
    }
    override func flagsChanged(with event: NSEvent) {
        guard controller?.keyboardCaptured == true else { return }
        for (flag, key): (NSEvent.ModifierFlags, UInt16) in [(.shift, 0x2A), (.control, 0x1D), (.option, 0x38), (.command, 0x15B)] {
            if modifiers.contains(flag) != event.modifierFlags.contains(flag), flag != .command || remoteShortcuts {
                controller?.sendKey(key, down: event.modifierFlags.contains(flag))
            }
        }
        modifiers = event.modifierFlags
    }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { controller?.setInputFocus(focusID, focused: true) }
        return result
    }
    override func resignFirstResponder() -> Bool { controller?.setInputFocus(focusID, focused: false); releaseInput(); return super.resignFirstResponder() }
    func dismantle() {
        resizeTask?.cancel(); resizeTask = nil
        windowObservers.forEach(NotificationCenter.default.removeObserver); windowObservers = []
        controller?.setInputFocus(focusID, focused: false); releaseInput()
    }
    func releaseInput() {
        controller?.releaseKeys(); modifiers = []
        for button in pointerButtons { controller?.pointer(flags: button, x: Int(lastPointer.x), y: Int(lastPointer.y)) }
        pointerButtons.removeAll(); unmarkText()
    }
    func insertText(_ string: Any, replacementRange: NSRange) { controller?.sendText((string as? NSAttributedString)?.string ?? (string as? String ?? "")); unmarkText() }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) { marked = (string as? NSAttributedString) ?? NSAttributedString(string: string as? String ?? "") }
    func unmarkText() { marked = NSAttributedString(string: "") }
    func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }
    func markedRange() -> NSRange { marked.length == 0 ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: marked.length) }
    func hasMarkedText() -> Bool { marked.length > 0 }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect { window?.convertToScreen(convert(NSRect(x: 20, y: 20, width: 1, height: 20), to: nil)) ?? .zero }
    func characterIndex(for point: NSPoint) -> Int { 0 }
    override func doCommand(by selector: Selector) { }
    private static let specialKeys: [UInt16: UInt16] = [36:0x1C,48:0x0F,51:0x0E,53:0x01,117:0x153,123:0x14B,124:0x14D,125:0x150,126:0x148,115:0x147,119:0x14F,116:0x149,121:0x151,122:0x3B,120:0x3C,99:0x3D,118:0x3E,96:0x3F,97:0x40,98:0x41,100:0x42,101:0x43,109:0x44,103:0x57,111:0x58]
    private static let physicalKeys: [UInt16: UInt16] = [0:0x1E,1:0x1F,2:0x20,3:0x21,4:0x23,5:0x22,6:0x2C,7:0x2D,8:0x2E,9:0x2F,11:0x30,12:0x10,13:0x11,14:0x12,15:0x13,16:0x15,17:0x14,31:0x18,32:0x16,34:0x17,35:0x19,37:0x26,38:0x24,40:0x25,45:0x31,46:0x32,49:0x39]
}

@MainActor
final class RDPFullscreenWindows: NSObject, NSWindowDelegate {
    private weak var controller: RDPSessionController?
    private var windows: [NSWindow] = []
    private var screenObserver: NSObjectProtocol?
    init(controller: RDPSessionController) { self.controller = controller }
    func open() throws {
        guard let controller else { return }
        close()
        let ids = controller.configuration.settings.screenIDs
        let layout = try RDPScreenCatalog.layout(ids: ids.isEmpty ? Array(RDPScreenCatalog.screens.prefix(1).map(\.id)) : ids)
        if layout.count > 1 {
            let width = (layout.map { $0.x + $0.width }.max() ?? 0) - (layout.map(\.x).min() ?? 0)
            let height = (layout.map { $0.y + $0.height }.max() ?? 0) - (layout.map(\.y).min() ?? 0)
            guard controller.frame?.width == width, controller.frame?.height == height else { throw RDPValidationError.invalidLayout }
        }
        for monitor in layout {
            guard let screen = RDPScreenCatalog.screens.first(where: { $0.id == monitor.screenID })?.screen else { continue }
            let window = NSWindow(contentRect: screen.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false, screen: screen)
            window.title = controller.configuration.name + " — RDP"
            window.isReleasedWhenClosed = false; window.delegate = self
            window.contentView = NSHostingView(rootView: RDPFullscreenContent(controller: controller, monitor: layout.count > 1 ? monitor : nil, close: { [weak self] in self?.close() }))
            window.collectionBehavior = [.fullScreenPrimary]
            windows.append(window); window.makeKeyAndOrderFront(nil); window.toggleFullScreen(nil)
        }
        controller.showingFullscreen = true
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }
    func close() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }; screenObserver = nil
        let old = windows; windows = []
        old.forEach { $0.delegate = nil; $0.close() }
        controller?.showingFullscreen = false
    }
    func windowWillClose(_ notification: Notification) { close() }
}

private struct RDPFullscreenContent: View {
    @ObservedObject var controller: RDPSessionController
    let monitor: RDPMonitor?
    let close: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(controller.configuration.name); Spacer(); Button("退出全屏", action: close) }.padding(8)
            RDPDesktopRepresentable(controller: controller, monitor: monitor)
        }.onAppear { controller.setVisible(true) }
    }
}

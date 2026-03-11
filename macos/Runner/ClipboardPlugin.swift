import Carbon
import Cocoa
import FlutterMacOS
import ServiceManagement
import UniformTypeIdentifiers
import Vision

@objc class ClipboardPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    // 全局事件监听器
    private var globalEventMonitor: Any?

    // 快捷键信息结构
    private struct HotkeyInfo {
        let keyCode: UInt16
        let modifiers: NSEvent.ModifierFlags
        let ignoreRepeat: Bool
        let lastTriggerTime: CFTimeInterval  // 添加防抖时间戳
        let carbonHotKeyRef: EventHotKeyRef?  // Carbon热键引用
        let hotKeyID: UInt32?  // Carbon热键ID
    }

    // 注册的快捷键
    private var registeredHotkeys: [String: HotkeyInfo] = [:]

    // Carbon热键ID计数器
    private var nextHotKeyID: Int32 = 1

    // 快捷键防抖间隔（毫秒）
    private let hotkeyDebounceInterval: CFTimeInterval = 0.1  // 100ms

    // 系统快捷键缓存
    private var systemHotkeysCache: Set<String> = []
    private var systemHotkeysCacheTime: CFTimeInterval = 0
    private let systemHotkeysCacheInterval: CFTimeInterval = 10.0  // 缓存10秒

    // 应用感知快捷键管理
    private var currentFrontApp: String?
    private var lastAppCheckTime: CFTimeInterval = 0
    private let appCheckInterval: CFTimeInterval = 1.0  // 1秒检查一次
    private var developerModeEnabled: Bool = false

    // Flutter方法通道
    private var channel: FlutterMethodChannel?
    private var eventChannel: FlutterEventChannel?
    private var eventSink: FlutterEventSink?

    // Security-Scoped Bookmarks 访问缓存
    private var accessingBookmarks: [String: URL] = [:]

    // 权限缓存机制
    private var lastClipboardSequence: Int = -1
    private var lastSequenceCheckTime: Date = Date.distantPast
    private let sequenceCacheInterval: TimeInterval = 0.5  // 500ms 缓存间隔

    // 类型缓存机制
    private var lastClipboardType: [String: Any]?
    private var lastTypeCheckTime: Date = Date.distantPast
    private var lastTypeSequence: Int = -1
    private var clipboardWatcherTimer: Timer?
    private let clipboardWatcherInterval: TimeInterval = 0.25
    private var lastEmittedClipboardSequence: Int = -1

    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "clipboard_service", binaryMessenger: registrar.messenger)
        let eventChannel = FlutterEventChannel(
            name: "clipboard_events", binaryMessenger: registrar.messenger)
        let instance = ClipboardPlugin()
        instance.channel = channel
        instance.eventChannel = eventChannel
        registrar.addMethodCallDelegate(instance, channel: channel)
        eventChannel.setStreamHandler(instance)
    }

    deinit {
        stopClipboardWatcher()
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "test":
            result("ClipboardPlugin is working on macOS")
        case "getClipboardFormats":
            getClipboardFormats(result: result)
        case "getClipboardType":
            getClipboardType(result: result)
        case "getClipboardSequence":
            getClipboardSequence(result: result)
        case "getClipboardFilePaths":
            getClipboardFilePaths(result: result)
        case "getClipboardImageData":
            getClipboardImageData(result: result)
        case "getClipboardImage":
            getClipboardImageData(result: result)
        case "getRichTextData":
            getRichTextData(call: call, result: result)
        case "setClipboardImage":
            setClipboardImage(call: call, result: result)
        case "setClipboardFile":
            setClipboardFile(call: call, result: result)
        case "performOCR":
            performOCR(call: call, result: result)
        case "isOCRAvailable":
            isOCRAvailable(result: result)
        case "getSupportedOCRLanguages":
            getSupportedOCRLanguages(result: result)
        case "isHotkeySupported":
            isHotkeySupported(result: result)
        case "registerHotkey":
            registerHotkey(call: call, result: result)
        case "unregisterHotkey":
            unregisterHotkey(call: call, result: result)
        case "isSystemHotkey":
            isSystemHotkey(call: call, result: result)
        case "activateApp":
            activateApp(result: result)
        case "isAutostartEnabled":
            isAutostartEnabled(result: result)
        case "enableAutostart":
            enableAutostart(result: result)
        case "disableAutostart":
            disableAutostart(result: result)
        case "pickDirectoryForBookmark":
            pickDirectoryForBookmark(call: call, result: result)
        case "startBookmarkAccess":
            startBookmarkAccess(call: call, result: result)
        case "stopBookmarkAccess":
            stopBookmarkAccess(call: call, result: result)
        case "removeBookmark":
            removeBookmark(call: call, result: result)
        case "setDeveloperMode":
            setDeveloperMode(call: call, result: result)
        case "getCurrentApp":
            getCurrentApp(result: result)
        case "getHotkeyStats":
            getHotkeyStats(result: result)
        case "getPhysicalScreenSize":
            getPhysicalScreenSize(result: result)
        case "isLoginLaunch":
            isLoginLaunch(result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
        -> FlutterError?
    {
        eventSink = events
        startClipboardWatcher()
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        stopClipboardWatcher()
        eventSink = nil
        return nil
    }

    private func startClipboardWatcher() {
        stopClipboardWatcher()

        let currentSequence = NSPasteboard.general.changeCount
        lastClipboardSequence = currentSequence
        lastEmittedClipboardSequence = currentSequence
        lastSequenceCheckTime = Date()

        clipboardWatcherTimer = Timer.scheduledTimer(withTimeInterval: clipboardWatcherInterval, repeats: true) {
            [weak self] _ in
            self?.emitClipboardEventIfNeeded()
        }

        if let clipboardWatcherTimer {
            RunLoop.main.add(clipboardWatcherTimer, forMode: .common)
        }
    }

    private func stopClipboardWatcher() {
        clipboardWatcherTimer?.invalidate()
        clipboardWatcherTimer = nil
        lastEmittedClipboardSequence = NSPasteboard.general.changeCount
    }

    private func emitClipboardEventIfNeeded() {
        guard let eventSink else { return }

        let now = Date()
        let currentSequence = NSPasteboard.general.changeCount
        guard currentSequence != lastEmittedClipboardSequence else { return }

        lastEmittedClipboardSequence = currentSequence
        lastClipboardSequence = currentSequence
        lastSequenceCheckTime = now

        eventSink(buildClipboardEvent(sequence: currentSequence, timestamp: now))
    }

    private func buildClipboardEvent(sequence: Int, timestamp: Date) -> [String: Any] {
        [
            "sequence": sequence,
            "timestamp": Int(timestamp.timeIntervalSince1970 * 1000),
            "platform": "macos",
            "source": "watcher",
            "monitoringIntervalMs": Int(clipboardWatcherInterval * 1000)
        ]
    }

    private func getClipboardFormats(result: @escaping FlutterResult) {
        let pasteboard = NSPasteboard.general
        let types = pasteboard.types ?? []
        var availableFormats: [String: Any] = [:]

        // 获取序列号
        let sequence = pasteboard.changeCount

        // 获取时间戳
        let timestamp = Date()

        NSLog("ClipboardPlugin: Available pasteboard types: %@", types.map { $0.rawValue })

        // 检查文件格式 - 使用正确的方法
        if types.contains(.fileURL) {
            NSLog("ClipboardPlugin: Found .fileURL type, checking for files...")
            if let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [NSURL] {
                let filePaths = fileURLs.compactMap { $0.path }
                if !filePaths.isEmpty {
                    availableFormats["files"] = filePaths
                    NSLog("ClipboardPlugin: Found %d files: %@", filePaths.count, filePaths)
                } else {
                    NSLog("ClipboardPlugin: No file paths found from NSURLs")
                }
            } else {
                NSLog("ClipboardPlugin: Failed to read file URLs")
            }
        } else {
            NSLog("ClipboardPlugin: No .fileURL type found")
        }

        // 检查图片格式
        let imageTypes: [NSPasteboard.PasteboardType] = [
            .png, .tiff,
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("public.image"),
            NSPasteboard.PasteboardType("com.compuserve.gif"),
            NSPasteboard.PasteboardType("com.microsoft.bmp"),
            NSPasteboard.PasteboardType("org.webmproject.webp"),
            NSPasteboard.PasteboardType("public.heic"),
            NSPasteboard.PasteboardType("public.heif")
        ]

        for imageType in imageTypes {
            if types.contains(imageType) {
                if let imageData = pasteboard.data(forType: imageType) {
                    // 将图片数据转换为字节数组
                    let byteArray = [UInt8](imageData)
                    availableFormats["image"] = byteArray
                    break
                }
            }
        }

        // 检查RTF格式
        if types.contains(.rtf) {
            if let rtfData = pasteboard.data(forType: .rtf),
               let rtfString = String(data: rtfData, encoding: .utf8) {
                availableFormats["rtf"] = rtfString
            }
        }

        // 检查HTML格式
        if types.contains(.html) {
            if let htmlData = pasteboard.data(forType: .html),
               let htmlString = String(data: htmlData, encoding: .utf8) {
                availableFormats["html"] = htmlString
            }
        }

        // 检查文本格式
        if types.contains(.string) {
            if let text = pasteboard.string(forType: .string) {
                availableFormats["text"] = text
            }
        }

        // 如果没有找到任何格式，尝试获取纯文本作为备用
        if availableFormats.isEmpty {
            if let text = pasteboard.string(forType: .string) {
                availableFormats["text"] = text
            }
        }

        let clipboardInfo: [String: Any] = [
            "sequence": sequence,
            "formats": availableFormats,
            "timestamp": timestamp.timeIntervalSince1970 * 1000, // 转换为毫秒
            "availableTypes": types.map { $0.rawValue }
        ]

        NSLog("ClipboardPlugin: Returning %d formats: %@", availableFormats.keys.count, Array(availableFormats.keys))
        result(clipboardInfo)
    }

    private func getClipboardType(result: @escaping FlutterResult) {
        let pasteboard: NSPasteboard = NSPasteboard.general
        let currentSequence = pasteboard.changeCount
        let now = Date()

        // 如果剪贴板内容没有变化且缓存有效，直接返回缓存
        if let cachedType = lastClipboardType,
            currentSequence == lastTypeSequence,
            now.timeIntervalSince(lastTypeCheckTime) < sequenceCacheInterval
        {
            result(cachedType)
            return
        }

        // 使用新的多格式检测方法
        let clipboardInfo = getClipboardFormats(pasteboard: pasteboard, sequence: currentSequence, timestamp: now)

        // 更新缓存
        lastClipboardType = clipboardInfo
        lastTypeCheckTime = now
        lastTypeSequence = currentSequence

        result(clipboardInfo)
    }

    /// 新的多格式检测方法 - 检测所有可用格式，不优先选择
    private func getClipboardFormats(pasteboard: NSPasteboard, sequence: Int, timestamp: Date) -> [String: Any] {
        let types = pasteboard.types ?? []
        var availableFormats: [String: Any] = [:]

        NSLog("ClipboardPlugin: Checking available formats: %@", types.map { $0.rawValue })

        // 检查 RTF 格式
        if types.contains(.rtf) {
            if let rtfData = pasteboard.data(forType: .rtf) {
                if let rtfString = String(data: rtfData, encoding: .utf8) {
                    availableFormats["rtf"] = rtfString
                    NSLog("ClipboardPlugin: Found RTF data (%d bytes)", rtfData.count)
                }
            }
        }

        // 检查 HTML 格式
        if types.contains(.html) {
            if let htmlData = pasteboard.data(forType: .html) {
                if let htmlString = String(data: htmlData, encoding: .utf8) {
                    availableFormats["html"] = htmlString
                    NSLog("ClipboardPlugin: Found HTML data (%d bytes)", htmlData.count)
                }
            }
        }

        // 检查文件格式
        if types.contains(.fileURL) {
            if let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [NSURL] {
                let filePaths = fileURLs.compactMap { $0.path }
                if !filePaths.isEmpty {
                    availableFormats["files"] = filePaths
                    NSLog("ClipboardPlugin: Found %d files", filePaths.count)
                }
            }
        }

        // 检查图片格式
        let imageTypes: [NSPasteboard.PasteboardType] = [
            .png, .tiff,
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("public.image"),
            NSPasteboard.PasteboardType("com.compuserve.gif"),
            NSPasteboard.PasteboardType("com.microsoft.bmp"),
            NSPasteboard.PasteboardType("org.webmproject.webp"),
            NSPasteboard.PasteboardType("public.heic"),
            NSPasteboard.PasteboardType("public.heif")
        ]

        for imageType in imageTypes {
            if types.contains(imageType) {
                if let imageData = pasteboard.data(forType: imageType) {
                    // 将图片数据转换为字节数组
                    let byteArray = [UInt8](imageData)
                    availableFormats["image"] = byteArray
                    NSLog("ClipboardPlugin: Found image data (%d bytes)", imageData.count)
                    break
                }
            }
        }

        // 检查文本格式
        if types.contains(.string) {
            if let string = pasteboard.string(forType: .string) {
                availableFormats["text"] = string
                NSLog("ClipboardPlugin: Found text data (%d characters)", string.count)
            }
        }

        // 构建返回信息
        let clipboardInfo: [String: Any] = [
            "sequence": sequence,
            "formats": availableFormats,
            "timestamp": timestamp.timeIntervalSince1970,
            "availableTypes": types.map { $0.rawValue }
        ]

        NSLog("ClipboardPlugin: Found \(availableFormats.keys.count) formats: \(availableFormats.keys)")
        return clipboardInfo
    }

    private func getClipboardSequence(result: @escaping FlutterResult) {
        let now = Date()

        // 如果距离上次检查时间小于缓存间隔，直接返回缓存的值
        if now.timeIntervalSince(lastSequenceCheckTime) < sequenceCacheInterval
            && lastClipboardSequence != -1
        {
            result(lastClipboardSequence)
            return
        }

        // 更新缓存
        let pasteboard = NSPasteboard.general
        lastClipboardSequence = pasteboard.changeCount
        lastSequenceCheckTime = now

        result(lastClipboardSequence)
    }

    private func getClipboardFilePaths(result: @escaping FlutterResult) {
        let pasteboard = NSPasteboard.general

        if let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [NSURL]
        {
            let filePaths = fileURLs.compactMap { $0.path }
            result(filePaths)
        } else {
            result(nil)
        }
    }

    private func getClipboardImageData(result: @escaping FlutterResult) {
        let pasteboard = NSPasteboard.general
        let types = pasteboard.types ?? []

        NSLog("ClipboardPlugin: Available pasteboard types: %@", types.map { $0.rawValue })

        var imageData: Data?
        var foundType: String?

        // 按优先级尝试获取图片数据
        if let pngData = pasteboard.data(forType: .png) {
            imageData = pngData
            foundType = "png"
        } else if let tiffData = pasteboard.data(forType: .tiff) {
            imageData = tiffData
            foundType = "tiff"
        } else if let jpegData = pasteboard.data(
            forType: NSPasteboard.PasteboardType("public.jpeg"))
        {
            imageData = jpegData
            foundType = "jpeg"
        } else if let genericImage = pasteboard.data(
            forType: NSPasteboard.PasteboardType("public.image"))
        {
            imageData = genericImage
            foundType = "public.image"
        } else if let gifData = pasteboard.data(
            forType: NSPasteboard.PasteboardType("com.compuserve.gif"))
        {
            imageData = gifData
            foundType = "gif"
        } else if let bmpData = pasteboard.data(
            forType: NSPasteboard.PasteboardType("com.microsoft.bmp"))
        {
            imageData = bmpData
            foundType = "bmp"
        } else if let webpData = pasteboard.data(
            forType: NSPasteboard.PasteboardType("org.webmproject.webp"))
        {
            imageData = webpData
            foundType = "webp"
        } else if let heicData = pasteboard.data(
            forType: NSPasteboard.PasteboardType("public.heic"))
        {
            imageData = heicData
            foundType = "heic"
        } else if let heifData = pasteboard.data(
            forType: NSPasteboard.PasteboardType("public.heif"))
        {
            imageData = heifData
            foundType = "heif"
        } else {
            // 尝试其他可能的图片类型
            imageData = _tryGetAnyImageData(from: pasteboard)
            if imageData != nil {
                foundType = "other"
            }
        }

        if let data = imageData, let type = foundType {
            NSLog(
                "ClipboardPlugin: Found image data of type %@ with size %d bytes", type, data.count)
            result(FlutterStandardTypedData(bytes: data))
        } else {
            NSLog("ClipboardPlugin: No image data found")
            result(nil)
        }
    }

    private func getRichTextData(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
            let type = args["type"] as? String
        else {
            result(
                FlutterError(
                    code: "INVALID_ARGUMENT", message: "Invalid type parameter", details: nil))
            return
        }

        let pasteboard = NSPasteboard.general

        switch type.lowercased() {
        case "rtf":
            if let rtfData = pasteboard.data(forType: .rtf) {
                if let rtfString = String(data: rtfData, encoding: .utf8) {
                    NSLog("ClipboardPlugin: Found RTF data (%d bytes)", rtfData.count)
                    result(rtfString)
                } else {
                    NSLog("ClipboardPlugin: Failed to decode RTF data")
                    result(nil)
                }
            } else {
                result(nil)
            }
        case "html":
            if let htmlData = pasteboard.data(forType: .html) {
                if let htmlString = String(data: htmlData, encoding: .utf8) {
                    NSLog("ClipboardPlugin: Found HTML data (%d bytes)", htmlData.count)
                    result(htmlString)
                } else {
                    NSLog("ClipboardPlugin: Failed to decode HTML data")
                    result(nil)
                }
            } else {
                result(nil)
            }
        default:
            result(
                FlutterError(
                    code: "UNSUPPORTED_TYPE", message: "Unsupported rich text type: \(type)",
                    details: nil))
        }
    }

    private func detectFileType(path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let pathExtension = url.pathExtension.lowercased()

        // 图片文件
        let imageExtensions = [
            "png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "tif", "svg", "ico", "heic", "heif",
        ]
        if imageExtensions.contains(pathExtension) {
            return "image"
        }

        // 音频文件
        let audioExtensions = ["mp3", "wav", "aac", "flac", "ogg", "m4a", "wma", "aiff", "au"]
        if audioExtensions.contains(pathExtension) {
            return "audio"
        }

        // 视频文件
        let videoExtensions = [
            "mp4", "avi", "mov", "wmv", "flv", "webm", "mkv", "m4v", "3gp", "ts",
        ]
        if videoExtensions.contains(pathExtension) {
            return "video"
        }

        // 文档文件
        let documentExtensions = [
            "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "pages", "numbers",
            "keynote",
        ]
        if documentExtensions.contains(pathExtension) {
            return "document"
        }

        // 压缩文件
        let archiveExtensions = ["zip", "rar", "7z", "tar", "gz", "bz2", "xz"]
        if archiveExtensions.contains(pathExtension) {
            return "archive"
        }

        // 代码文件
        let codeExtensions = [
            "swift", "dart", "js", "ts", "py", "java", "cpp", "c", "h", "m", "mm", "go", "rs",
            "php", "rb", "kt",
        ]
        if codeExtensions.contains(pathExtension) {
            return "code"
        }

        return "file"
    }

    // 说明：细粒度文本/颜色判定已收敛到 Dart 层；
    // 本方法保留但不再在原生侧被调用，仅供参考/后续清理。
    private func detectTextType(text: String) -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 检查是否是颜色值
        if isColorValue(text: trimmedText) {
            return "color"
        }

        // 检查是否是 URL
        if isURL(text: trimmedText) {
            return "url"
        }

        // 检查是否是邮箱
        if isEmail(text: trimmedText) {
            return "email"
        }

        // 检查是否是文件路径
        if isFilePath(text: trimmedText) {
            return "path"
        }

        // 检查是否是 JSON
        if isJSON(text: trimmedText) {
            return "json"
        }

        // 检查是否是 XML/HTML
        if isXMLOrHTML(text: trimmedText) {
            return "markup"
        }

        return "plain"
    }

    // 说明：颜色值判断逻辑已迁移至 Dart 的 ColorUtils；
    // 原生侧保留此方法但不参与运行时分类。
    private func isColorValue(text: String) -> Bool {
        // 十六进制颜色（与Dart端保持一致，支持可选的#号和4位颜色）
        let hexPattern = "^#?(?:[A-Fa-f0-9]{3}|[A-Fa-f0-9]{4}|[A-Fa-f0-9]{6}|[A-Fa-f0-9]{8})$"
        if text.range(of: hexPattern, options: .regularExpression) != nil {
            return true
        }

        // RGB颜色（严格匹配0-255范围）
        let rgbPattern =
            "^rgb\\s*\\(\\s*(0|255|25[0-4]|2[0-4]\\d|[01]?\\d\\d?)\\s*,\\s*(0|255|25[0-4]|2[0-4]\\d|[01]?\\d\\d?)\\s*,\\s*(0|255|25[0-4]|2[0-4]\\d|[01]?\\d\\d?)\\s*\\)$"
        if text.range(of: rgbPattern, options: .regularExpression) != nil {
            return true
        }

        // RGBA颜色（alpha值0-1）
        let rgbaPattern =
            "^rgba\\s*\\(\\s*(0|255|25[0-4]|2[0-4]\\d|[01]?\\d\\d?)\\s*,\\s*(0|255|25[0-4]|2[0-4]\\d|[01]?\\d\\d?)\\s*,\\s*(0|255|25[0-4]|2[0-4]\\d|[01]?\\d\\d?)\\s*,\\s*(0|1|0\\.[0-9]+|1\\.0)\\s*\\)$"
        if text.range(of: rgbaPattern, options: .regularExpression) != nil {
            return true
        }

        // HSL颜色（角度0-360，百分比0-100%）
        let hslPattern =
            "^hsl\\s*\\(\\s*(360|3[0-5]\\d|[0-2]?\\d\\d?)\\s*,\\s*(100%|\\d{1,2}%)\\s*,\\s*(100%|\\d{1,2}%)\\s*\\)$"
        if text.range(of: hslPattern, options: .regularExpression) != nil {
            return true
        }

        // HSLA颜色（含透明度）
        let hslaPattern =
            "^hsla\\s*\\(\\s*(360|3[0-5]\\d|[0-2]?\\d\\d?)\\s*,\\s*(100%|\\d{1,2}%)\\s*,\\s*(100%|\\d{1,2}%)\\s*,\\s*(0|1|0\\.[0-9]+|1\\.0)\\s*\\)$"
        if text.range(of: hslaPattern, options: .regularExpression) != nil {
            return true
        }

        return false
    }

    private func isURL(text: String) -> Bool {
        if let url = URL(string: text), url.scheme != nil {
            return true
        }
        return false
    }

    private func isEmail(text: String) -> Bool {
        let emailPattern = "^[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$"
        return text.range(of: emailPattern, options: .regularExpression) != nil
    }

    private func isFilePath(text: String) -> Bool {
        return text.hasPrefix("file://") || text.contains("/") || text.contains("\\")
    }

    private func isJSON(text: String) -> Bool {
        guard let data = text.data(using: .utf8) else { return false }
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [])
            return true
        } catch {
            return false
        }
    }

    private func isXMLOrHTML(text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("<") && trimmed.hasSuffix(">")
    }

    private func setClipboardImage(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
            let imageData = args["imageData"] as? FlutterStandardTypedData
        else {
            result(
                FlutterError(code: "INVALID_ARGUMENT", message: "Invalid image data", details: nil))
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let data = imageData.data
        pasteboard.setData(data, forType: .png)

        result(true)
    }

    private func setClipboardFile(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
            let filePath = args["filePath"] as? String
        else {
            result(
                FlutterError(code: "INVALID_ARGUMENT", message: "Invalid file path", details: nil))
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        // 创建文件URL
        let fileURL = URL(fileURLWithPath: filePath)

        // 检查文件是否存在
        guard FileManager.default.fileExists(atPath: filePath) else {
            result(
                FlutterError(
                    code: "FILE_NOT_FOUND", message: "File does not exist: \(filePath)",
                    details: nil))
            return
        }

        // 使用正确的方式将文件写入剪贴板
        // 方法1: 使用 NSFilenamesPboardType (传统方法)
        pasteboard.setPropertyList(
            [filePath], forType: NSPasteboard.PasteboardType(rawValue: "NSFilenamesPboardType"))

        // 方法2: 同时使用现代的 fileURL 类型
        pasteboard.setPropertyList([fileURL.absoluteString], forType: .fileURL)

        // 方法3: 对于图片文件，同时设置图片数据
        let fileExtension = fileURL.pathExtension.lowercased()
        let imageExtensions = [
            "png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "tif", "svg", "ico", "heic", "heif",
        ]
        if imageExtensions.contains(fileExtension) {
            if let imageData = try? Data(contentsOf: fileURL) {
                pasteboard.setData(imageData, forType: .png)
            }
        }

        result(true)
    }

    // 辅助方法：检查是否有任何图片类型
    private func _hasAnyImageType(types: [NSPasteboard.PasteboardType]) -> Bool {
        let imageTypes = [
            "public.image",
            "public.jpeg-2000",
            "public.camera-raw-image",
            "com.adobe.photoshop-image",
            "com.truevision.tga-image",
            "public.radiance",
            "public.pbm",
            "public.pvr",
            "com.ilm.openexr-image",
        ]

        for typeName in imageTypes {
            let type = NSPasteboard.PasteboardType(typeName)
            if types.contains(type) {
                NSLog("ClipboardPlugin: Found additional image type: %@", typeName)
                return true
            }
        }
        return false
    }

    // 辅助方法：尝试获取任何图片数据
    private func _tryGetAnyImageData(from pasteboard: NSPasteboard) -> Data? {
        let additionalImageTypes = [
            "public.image",
            "public.jpeg-2000",
            "public.camera-raw-image",
            "com.adobe.photoshop-image",
            "com.truevision.tga-image",
            "public.radiance",
            "public.pbm",
            "public.pvr",
            "com.ilm.openexr-image",
        ]

        for typeName in additionalImageTypes {
            let type = NSPasteboard.PasteboardType(typeName)
            if let data = pasteboard.data(forType: type), !data.isEmpty {
                NSLog(
                    "ClipboardPlugin: Found image data in additional type: %@ (%d bytes)", typeName,
                    data.count)
                return data
            }
        }

        NSLog("ClipboardPlugin: No additional image types found")
        return nil
    }

    // MARK: - OCR Methods

    private func performOCR(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
            let imageData = args["imageData"] as? FlutterStandardTypedData
        else {
            result(
                FlutterError(
                    code: "INVALID_ARGUMENT", message: "Missing imageData parameter", details: nil))
            return
        }

        NSLog("ClipboardPlugin: Starting OCR on image data (%d bytes)", imageData.data.count)

        // 创建NSImage
        guard let nsImage = NSImage(data: imageData.data) else {
            result(
                FlutterError(
                    code: "INVALID_IMAGE", message: "Cannot create NSImage from data", details: nil)
            )
            return
        }

        // 转换为CGImage
        guard let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            result(
                FlutterError(
                    code: "INVALID_IMAGE", message: "Cannot create CGImage from NSImage",
                    details: nil))
            return
        }

        // 可选的最小置信度过滤（需在闭包外声明以便捕获）
        let minConfidence = (args["minConfidence"] as? Double) ?? 0.0

        // 创建Vision文字识别请求
        let request = VNRecognizeTextRequest { (request, error) in
            DispatchQueue.main.async {
                if let error = error {
                    NSLog("ClipboardPlugin: OCR error: %@", error.localizedDescription)
                    result(
                        FlutterError(
                            code: "OCR_ERROR", message: error.localizedDescription, details: nil))
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    NSLog("ClipboardPlugin: No text observations found")
                    result(["text": "", "confidence": 0.0])
                    return
                }

                var recognizedText = ""
                var totalConfidence: Float = 0.0
                var observationCount = 0
                let threshold: Float = Float(minConfidence)

                for observation in observations {
                    guard let topCandidate = observation.topCandidates(1).first else { continue }
                    // 置信度过滤
                    if topCandidate.confidence >= threshold {
                        recognizedText += topCandidate.string + "\n"
                        totalConfidence += topCandidate.confidence
                        observationCount += 1
                        NSLog(
                            "ClipboardPlugin: Recognized text: '%@' (confidence: %.2f)",
                            topCandidate.string, topCandidate.confidence)
                    } else {
                        NSLog(
                            "ClipboardPlugin: Skipped low-confidence text: '%.2f' < '%.2f'",
                            topCandidate.confidence, threshold)
                    }
                }

                // 移除最后的换行符
                if recognizedText.hasSuffix("\n") {
                    recognizedText = String(recognizedText.dropLast())
                }

                let averageConfidence =
                    observationCount > 0 ? totalConfidence / Float(observationCount) : 0.0

                NSLog(
                    "ClipboardPlugin: OCR completed. Text: '%@', Average confidence: %.2f",
                    recognizedText, averageConfidence)

                result([
                    "text": recognizedText,
                    "confidence": Double(averageConfidence),
                ])
            }
        }

        // 配置OCR请求
        request.recognitionLevel = .accurate
        // 处理语言参数
        let langParam = (args["language"] as? String) ?? "auto"
        if langParam == "auto" {
            request.recognitionLanguages = ["en-US", "zh-Hans", "zh-Hant"]
        } else {
            request.recognitionLanguages = [langParam]
        }
        request.usesLanguageCorrection = true

        // 执行OCR请求
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try handler.perform([request])
            } catch {
                DispatchQueue.main.async {
                    NSLog("ClipboardPlugin: Failed to perform OCR: %@", error.localizedDescription)
                    result(
                        FlutterError(
                            code: "OCR_FAILED", message: error.localizedDescription, details: nil))
                }
            }
        }
    }

    /// 检查 OCR 是否可用
    private func isOCRAvailable(result: @escaping FlutterResult) {
        if #available(macOS 10.15, *) {
            result(true)
        } else {
            result(false)
        }
    }

    /// 返回系统支持的 OCR 语言列表
    private func getSupportedOCRLanguages(result: @escaping FlutterResult) {
        if #available(macOS 10.15, *) {
            do {
                var langs: [String]
                if #available(macOS 11.0, *) {
                    langs = try VNRecognizeTextRequest.supportedRecognitionLanguages(
                        for: .accurate, revision: VNRecognizeTextRequestRevision2)
                } else {
                    // 在 macOS 10.15 上使用 Revision1 以避免可用性编译错误
                    langs = try VNRecognizeTextRequest.supportedRecognitionLanguages(
                        for: .accurate, revision: VNRecognizeTextRequestRevision1)
                }
                result(langs)
            } catch {
                result(
                    FlutterError(
                        code: "LANG_QUERY_FAILED", message: error.localizedDescription, details: nil
                    ))
            }
        } else {
            result(["en-US", "zh-Hans", "zh-Hant"])  // 基本回退
        }
    }

    // MARK: - Hotkey Support

    /// 检查是否支持全局快捷键
    private func isHotkeySupported(result: @escaping FlutterResult) {
        // macOS 支持全局快捷键
        result(true)
    }

    /// 注册快捷键
    private func registerHotkey(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
            let action = args["action"] as? String,
            let keyString = args["key"] as? String
        else {
            result(
                FlutterError(code: "INVALID_ARGUMENT", message: "Invalid arguments", details: nil))
            return
        }
        let ignoreRepeat = (args["ignoreRepeat"] as? Bool) ?? true

        // 解析快捷键字符串 (例如: "Cmd+Shift+C")
        let components = keyString.components(separatedBy: "+")

        // 校验仅存在一个主键
        let modifierSet: Set<String> = ["cmd", "ctrl", "alt", "shift", "meta", "option"]
        let mainKeys = components.filter { !modifierSet.contains($0.lowercased()) }
        guard mainKeys.count == 1 else {
            result(
                FlutterError(
                    code: "INVALID_KEY", message: "Invalid key combination",
                    details: ["mainKeys": mainKeys]))
            return
        }

        guard let keyCode = parseKeyCode(from: components) else {
            result(FlutterError(code: "INVALID_KEY", message: "Invalid key code", details: nil))
            return
        }

        let modifiers = parseModifiers(from: components)

        // 注册快捷键
        let success = registerGlobalHotkey(
            action: action, keyCode: keyCode, modifiers: modifiers, ignoreRepeat: ignoreRepeat)
        result(success)
    }

    /// 取消注册快捷键
    private func unregisterHotkey(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
            let action = args["action"] as? String
        else {
            result(FlutterError(code: "INVALID_ARGUMENT", message: "Invalid action", details: nil))
            return
        }

        let success = unregisterGlobalHotkey(action: action)
        result(success)
    }

    /// 检查是否为系统快捷键
    private func isSystemHotkey(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
            let keyString = args["key"] as? String
        else {
            result(
                FlutterError(code: "INVALID_ARGUMENT", message: "Invalid key string", details: nil))
            return
        }

        let isSystem = isSystemHotkeyCached(keyString: keyString)
        result(isSystem)
    }

    /// 带缓存的系统快捷键检查
    private func isSystemHotkeyCached(keyString: String) -> Bool {
        let currentTime = CACurrentMediaTime()

        // 如果缓存过期，重新加载系统快捷键
        if currentTime - systemHotkeysCacheTime > systemHotkeysCacheInterval {
            loadSystemHotkeys()
            systemHotkeysCacheTime = currentTime
        }

        return systemHotkeysCache.contains(keyString)
    }

    /// 激活应用并带到前台
    private func activateApp(result: @escaping FlutterResult) {
        DispatchQueue.main.async {
            // 激活应用
            NSApp.activate(ignoringOtherApps: true)

            // 确保主窗口也激活
            if let window = NSApp.keyWindow {
                window.makeKeyAndOrderFront(nil)
            }

            result(true)
        }
    }

    /// 获取当前前台应用的Bundle ID
    private func getCurrentFrontApp() -> String? {
        let workspace = NSWorkspace.shared
        let frontApp = workspace.frontmostApplication
        return frontApp?.bundleIdentifier
    }

    /// 检查是否为开发应用
    private func isDevelopmentApp(_ bundleId: String) -> Bool {
        let devApps = [
            "com.apple.dt.Xcode",         // Xcode
            "com.microsoft.VSCode",       // VS Code
            "com.jetbrains.intellij",     // IntelliJ IDEA
            "com.jetbrains.intellij.ce",  // IntelliJ IDEA Community
            "com.jetbrains.AppCode",      // AppCode
            "com.jetbrains.CLion",        // CLion
            "com.jetbrains.DataGrip",     // DataGrip
            "com.jetbrains.PyCharm",      // PyCharm
            "com.jetbrains.Rider",        // Rider
            "com.jetbrains.RubyMine",     // RubyMine
            "com.jetbrains.WebStorm",     // WebStorm
            "com.sublimetext.3",          // Sublime Text
            "com.sublimetext.4",          // Sublime Text 4
            "org.vim.MacVim",            // MacVim
            "com.googlecode.iterm2",      // iTerm2
            "com.apple.Terminal",         // Terminal
            "com.github.wez.wezterm",    // WezTerm
            "io.alacritty",               // Alacritty
            "com.microsoft.vscode",       // VS Code
            "com.visualstudio.code.oss",  // VS Code OSS
            "com.google.AndroidStudio",   // Android Studio
            "com.oracle.java.jdk",        // Java tools
            "org.eclipse.eclipse",        // Eclipse
            "com.noodlesoft.Panini",      // Panini (Xcode extension)
        ]
        return devApps.contains(bundleId)
    }

    /// 检查是否为设计应用
    private func isDesignApp(_ bundleId: String) -> Bool {
        let designApps = [
            "com.adobe.Photoshop",        // Photoshop
            "com.adobe.Illustrator",      // Illustrator
            "com.adobe.AfterEffects",     // After Effects
            "com.adobe.PremierePro",      // Premiere Pro
            "com.adobe.Indesign",         // InDesign
            "com.sketch.sketch",          // Sketch
            "com.figma.Desktop",          // Figma
            "com.figma.agent",            // Figma Agent
            "com.bohemiancoding.sketch3", // Sketch 3
            "com.adobe.xd",               // Adobe XD
            "com.seriflabs.affinitydesigner", // Affinity Designer
            "com.seriflabs.affinityphoto", // Affinity Photo
            "com.protopie.studio",        // ProtoPie
            "com.invisionlabs.Invision",  // InVision
            "com.axure.axure rp",         // Axure RP
        ]
        return designApps.contains(bundleId)
    }

    /// 获取应用类型
    private func getAppType(_ bundleId: String) -> String {
        if isDevelopmentApp(bundleId) {
            return "development"
        } else if isDesignApp(bundleId) {
            return "design"
        } else if bundleId.hasPrefix("com.apple.") {
            return "system"
        }
        return "general"
    }

    /// 更新当前前台应用信息
    private func updateCurrentApp() {
        let now = CACurrentMediaTime()
        if now - lastAppCheckTime > appCheckInterval {
            currentFrontApp = getCurrentFrontApp()
            lastAppCheckTime = now
        }
    }

    /// 检查是否应该处理快捷键（基于应用感知）
    private func shouldProcessHotkey(_ keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        updateCurrentApp()

        guard let bundleId = currentFrontApp else { return true }

        // 开发模式下，在开发应用中允许更多非冲突快捷键
        if developerModeEnabled && isDevelopmentApp(bundleId) {
            // 扩展开发模式下的白名单，包含所有默认快捷键配置
            let allowedInDevMode: Set<String> = [
                "cmd+f8", "cmd+f9", "cmd+option+`", "cmd+control+v",  // 原有的
                "cmd+shift+f"  // 添加search动作的快捷键
            ]
            let keyString = createKeyString(keyCode: keyCode, modifiers: modifiers)
            return allowedInDevMode.contains(keyString)
        }

        // 普通模式下，避开最常见的冲突快捷键，但允许应用的默认快捷键
        if isDevelopmentApp(bundleId) || isDesignApp(bundleId) {
            let restrictedKeys: Set<String> = [
                "cmd+shift+o", "cmd+j", "cmd+shift+j", "cmd+option+j",
                "cmd+shift+b", "cmd+option+b", "cmd+control+b",
                "cmd+shift+c", "cmd+option+c", "cmd+control+c",
                "cmd+shift+d", "cmd+shift+e", "cmd+shift+k",
                "cmd+shift+l", "cmd+shift+m", "cmd+shift+n",
                "cmd+shift+p", "cmd+shift+r", "cmd+shift+u",
                "cmd+shift+w", "cmd+shift+y", "cmd+shift+z",
                "cmd+1", "cmd+2", "cmd+3", "cmd+4", "cmd+5",
                "cmd+6", "cmd+7", "cmd+8", "cmd+9", "cmd+0",
            ]
            // 允许应用的默认快捷键，即使在开发应用中
            let allowedAppKeys: Set<String> = [
                "cmd+option+`", "cmd+control+v", "cmd+f9", "cmd+f8", "cmd+shift+f"
            ]
            let keyString = createKeyString(keyCode: keyCode, modifiers: modifiers)
            return !restrictedKeys.contains(keyString) || allowedAppKeys.contains(keyString)
        }

        return true
    }

    /// 加载系统快捷键列表
    private func loadSystemHotkeys() {
        // 基础系统快捷键
        var hotkeys: Set<String> = [
            "cmd+q", "cmd+w", "cmd+tab", "cmd+space",
            "cmd+c", "cmd+v", "cmd+x", "cmd+z", "cmd+y",
            "cmd+a", "cmd+s", "cmd+f", "cmd+g", "cmd+h",
            "cmd+m", "cmd+n", "cmd+o", "cmd+p", "cmd+r",
            "cmd+t", "cmd+shift+3", "cmd+shift+4", "cmd+shift+5",
        ]

        // 添加Xcode和开发工具常用快捷键
        hotkeys.formUnion([
            "cmd+shift+o", "cmd+j", "cmd+shift+j", "cmd+option+j",
            "cmd+shift+b", "cmd+option+b", "cmd+control+b",
            "cmd+shift+c", "cmd+option+c", "cmd+control+c",
            "cmd+shift+d", "cmd+shift+e", "cmd+shift+k",
            "cmd+shift+l", "cmd+shift+m", "cmd+shift+n",
            "cmd+shift+p", "cmd+shift+r", "cmd+shift+u",
            "cmd+shift+w", "cmd+shift+y", "cmd+shift+z",
            "cmd+option+0", "cmd+option+1", "cmd+option+2",
            "cmd+option+3", "cmd+option+4", "cmd+option+5",
            "cmd+option+6", "cmd+option+7", "cmd+option+8",
            "cmd+option+9", "cmd+control+0", "cmd+control+1",
            "cmd+control+2", "cmd+control+3", "cmd+control+4",
            "cmd+control+5", "cmd+control+6", "cmd+control+7",
            "cmd+control+8", "cmd+control+9",
        ])

        // 添加IDE和编辑器常用快捷键
        hotkeys.formUnion([
            "cmd+1", "cmd+2", "cmd+3", "cmd+4", "cmd+5",
            "cmd+6", "cmd+7", "cmd+8", "cmd+9", "cmd+0",
            "cmd+-", "cmd+=", "cmd+[", "cmd+]", "cmd+\\",
            "cmd+;", "cmd+'", "cmd+,", "cmd+.", "cmd+/",
            "cmd+option+t", "cmd+option+w", "cmd+option+r",
            "cmd+control+t", "cmd+control+w", "cmd+control+r",
        ])

        // 添加功能键快捷键
        for i in 1...12 {
            hotkeys.insert("cmd+f\(i)")
            hotkeys.insert("cmd+shift+f\(i)")
            hotkeys.insert("cmd+option+f\(i)")
            hotkeys.insert("cmd+control+f\(i)")
            hotkeys.insert("ctrl+f\(i)")
            hotkeys.insert("ctrl+shift+f\(i)")
            hotkeys.insert("ctrl+option+f\(i)")
            hotkeys.insert("ctrl+control+f\(i)")
        }

        // 添加其他常用快捷键
        hotkeys.formUnion([
            "cmd+option+escape", "cmd+control+q", "ctrl+cmd+q",
            "cmd+option+d", "cmd+control+d", "cmd+shift+d",
            "cmd+option+f", "cmd+control+f", "cmd+option+h",
            "cmd+option+i", "cmd+option+j", "cmd+option+k",
            "cmd+option+l", "cmd+option+m", "cmd+option+n",
        ])

        systemHotkeysCache = hotkeys
        NSLog("ClipboardPlugin: Loaded %d system hotkeys", hotkeys.count)
    }

    /// 创建快捷键字符串
    private func createKeyString(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []

        if modifiers.contains(.command) {
            parts.append("cmd")
        }
        if modifiers.contains(.control) {
            parts.append("ctrl")
        }
        if modifiers.contains(.option) {
            parts.append("alt")
        }
        if modifiers.contains(.shift) {
            parts.append("shift")
        }

        // 将按键代码转换为字符
        if let keyChar = keyCodeToString(keyCode) {
            parts.append(keyChar.lowercased())
        } else {
            parts.append("unknown")
        }

        return parts.joined(separator: "+")
    }

    /// 按键映射表 - 统一维护按键代码和字符串的对应关系
    private let keyMappingTable: [UInt16: String] = [
        // 字母键
        0x00: "a", 0x01: "s", 0x02: "d", 0x03: "f",
        0x04: "h", 0x05: "g", 0x06: "z", 0x07: "x",
        0x08: "c", 0x09: "v", 0x0B: "b", 0x0C: "q",
        0x0D: "w", 0x0E: "e", 0x0F: "r", 0x10: "y",
        0x11: "t", 0x1F: "o", 0x20: "u", 0x22: "i",
        0x23: "p", 0x25: "l", 0x26: "j", 0x28: "k",
        0x2D: "n", 0x2E: "m",
        // 数字键（主键盘）
        0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x17: "5",
        0x16: "6", 0x1A: "7", 0x1C: "8", 0x19: "9", 0x1D: "0",
        // 数字键（小键盘）
        0x52: "0", 0x53: "1", 0x54: "2", 0x55: "3", 0x56: "4",
        0x57: "5", 0x58: "6", 0x59: "7", 0x5A: "8", 0x5B: "9",
        // 符号键
        0x18: "=", 0x1B: "-", 0x1E: "]", 0x21: "[", 0x27: "'",
        0x29: ";", 0x2A: "\\", 0x2B: ",", 0x2C: "/", 0x2F: ".",
        0x32: "`",
        // 特殊键
        0x24: "enter", 0x30: "tab", 0x31: "space", 0x33: "delete",
        0x35: "escape",
        // F键
        0x7A: "f1", 0x78: "f2", 0x63: "f3", 0x76: "f4",
        0x60: "f5", 0x61: "f6", 0x62: "f7", 0x64: "f8",
        0x65: "f9", 0x6D: "f10", 0x67: "f11", 0x6F: "f12",
    ]

    /// 将按键代码转换为字符串
    private func keyCodeToString(_ keyCode: UInt16) -> String? {
        return keyMappingTable[keyCode]
    }

    // MARK: - Modern Hotkey Implementation

    /// 注册全局快捷键（使用Carbon API确保后台工作）
    private func registerGlobalHotkey(
        action: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags, ignoreRepeat: Bool
    ) -> Bool {
        // 取消之前的注册并处理返回值
        let unregOk = unregisterGlobalHotkey(action: action)
        if !unregOk {
            NSLog("ClipboardPlugin: Failed to unregister previous hotkey for action %@", action)
        }

        // 检查是否为系统快捷键（使用缓存）
        let keyString = createKeyString(keyCode: keyCode, modifiers: modifiers)
        if isSystemHotkeyCached(keyString: keyString) {
            NSLog("ClipboardPlugin: Refusing to register system hotkey: %@", keyString)
            return false
        }

        // 使用Carbon API注册全局快捷键
        var carbonHotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(
            signature: OSType(0x6874_666B),  // 'htfk'
            id: UInt32(nextHotKeyID))
        nextHotKeyID += 1

        // 转换修饰符
        var carbonModifiers: UInt32 = 0
        if modifiers.contains(.command) {
            carbonModifiers |= UInt32(cmdKey)
        }
        if modifiers.contains(.shift) {
            carbonModifiers |= UInt32(shiftKey)
        }
        if modifiers.contains(.option) {
            carbonModifiers |= UInt32(optionKey)
        }
        if modifiers.contains(.control) {
            carbonModifiers |= UInt32(controlKey)
        }

        // 注册Carbon热键
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            carbonModifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &carbonHotKeyRef
        )

        if status != noErr {
            NSLog(
                "ClipboardPlugin: Failed to register Carbon hotkey for action %@ with key %@, status: %d",
                action, keyString, status)
            // 如果Carbon注册失败，回退到NSEvent
            return registerNSEventHotkey(
                action: action, keyCode: keyCode, modifiers: modifiers, ignoreRepeat: ignoreRepeat)
        }

        // 保存快捷键配置，包含当前时间用于防抖
        let currentTime = CACurrentMediaTime()
        registeredHotkeys[action] = HotkeyInfo(
            keyCode: keyCode,
            modifiers: modifiers,
            ignoreRepeat: ignoreRepeat,
            lastTriggerTime: currentTime,
            carbonHotKeyRef: carbonHotKeyRef,
            hotKeyID: hotKeyID.id
        )

        // 设置Carbon事件处理器
        if carbonHotKeyRef != nil {
            setupCarbonEventHandler()
        }

        NSLog(
            "ClipboardPlugin: Successfully registered Carbon hotkey for action %@ with key %@",
            action, keyString)
        return true
    }

    /// 回退到NSEvent监听器
    private func registerNSEventHotkey(
        action: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags, ignoreRepeat: Bool
    ) -> Bool {
        // 保存快捷键配置，包含当前时间用于防抖
        let currentTime = CACurrentMediaTime()
        registeredHotkeys[action] = HotkeyInfo(
            keyCode: keyCode,
            modifiers: modifiers,
            ignoreRepeat: ignoreRepeat,
            lastTriggerTime: currentTime,
            carbonHotKeyRef: nil,
            hotKeyID: nil
        )

        // 如果这是第一个快捷键，启动全局监听器
        if globalEventMonitor == nil {
            setupGlobalEventMonitor()
        }

        NSLog(
            "ClipboardPlugin: Successfully registered NSEvent hotkey for action %@ with key %@",
            action, createKeyString(keyCode: keyCode, modifiers: modifiers))
        return true
    }

    /// 取消注册全局快捷键
    private func unregisterGlobalHotkey(action: String) -> Bool {
        guard let hotkeyInfo = registeredHotkeys[action] else {
            return true
        }

        // 如果是Carbon热键，取消注册
        if let carbonHotKeyRef = hotkeyInfo.carbonHotKeyRef {
            let status = UnregisterEventHotKey(carbonHotKeyRef)
            if status != noErr {
                NSLog(
                    "ClipboardPlugin: Failed to unregister Carbon hotkey for action %@, status: %d",
                    action, status)
            }
        }

        registeredHotkeys.removeValue(forKey: action)

        // 如果没有注册的快捷键了，停止全局监听器
        if registeredHotkeys.isEmpty {
            if globalEventMonitor != nil {
                NSEvent.removeMonitor(globalEventMonitor!)
                globalEventMonitor = nil
                NSLog("ClipboardPlugin: Stopped global event monitor - no hotkeys registered")
            }

            // 停止Carbon事件处理器
            stopCarbonEventHandler()
        }

        return true
    }

    /// 设置全局事件监听器
    private func setupGlobalEventMonitor() {
        // 使用更高效的事件监听器
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            self?.handleGlobalKeyEvent(event)
        }
        NSLog("ClipboardPlugin: Started global event monitor")
    }

    /// 设置Carbon事件处理器
    private func setupCarbonEventHandler() {
        var eventType = EventTypeSpec()
        eventType.eventClass = OSType(kEventClassKeyboard)
        eventType.eventKind = OSType(kEventHotKeyPressed)

        InstallEventHandler(
            GetEventDispatcherTarget(),
            { (nextHandler, theEvent, userData) -> OSStatus in
                let plugin = Unmanaged<ClipboardPlugin>.fromOpaque(userData!)
                    .takeUnretainedValue()
                return plugin.handleCarbonHotKeyEvent(theEvent)
            }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), nil)

        NSLog("ClipboardPlugin: Set up Carbon event handler")
    }

    /// 停止Carbon事件处理器
    private func stopCarbonEventHandler() {
        // Carbon事件处理器会在插件销毁时自动清理
        NSLog("ClipboardPlugin: Carbon event handler stopped")
    }

    /// 处理Carbon热键事件
    private func handleCarbonHotKeyEvent(_ event: EventRef?) -> OSStatus {
        guard let event = event else {
            return noErr
        }

        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        if status != noErr {
            return noErr
        }

        // 查找对应的动作
        for (action, hotkeyInfo) in registeredHotkeys {
            if let registeredID = hotkeyInfo.hotKeyID, registeredID == hotKeyID.id {
                // 匹配到正确的 ID
                let currentTime = CACurrentMediaTime()

                // 防抖检查
                if currentTime - hotkeyInfo.lastTriggerTime < hotkeyDebounceInterval {
                    continue
                }

                // 更新最后触发时间
                var updatedHotkey = hotkeyInfo
                updatedHotkey = HotkeyInfo(
                    keyCode: hotkeyInfo.keyCode,
                    modifiers: hotkeyInfo.modifiers,
                    ignoreRepeat: hotkeyInfo.ignoreRepeat,
                    lastTriggerTime: currentTime,
                    carbonHotKeyRef: hotkeyInfo.carbonHotKeyRef,
                    hotKeyID: hotkeyInfo.hotKeyID
                )
                registeredHotkeys[action] = updatedHotkey

                // 通知Flutter端
                DispatchQueue.main.async { [weak self] in
                    self?.channel?.invokeMethod("onHotkeyPressed", arguments: ["action": action])
                }

                NSLog("ClipboardPlugin: Carbon hotkey pressed for action: %@", action)
                // 找到匹配的 ID 后立即退出
                break
            }
        }

        return noErr
    }

    /// 处理全局按键事件
    private func handleGlobalKeyEvent(_ event: NSEvent) {
        let keyCode = event.keyCode
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let currentTime = CACurrentMediaTime()

        // 应用感知快捷键过滤
        guard shouldProcessHotkey(keyCode, modifiers: modifiers) else {
            NSLog("ClipboardPlugin: Skipping hotkey due to app conflict prevention")
            return
        }

        // 检查是否匹配任何注册的快捷键
        for (action, hotkey) in registeredHotkeys {
            // 忽略重复按键
            if hotkey.ignoreRepeat && event.isARepeat { continue }

            // 检查按键和修饰符是否匹配
            guard keyCode == hotkey.keyCode && modifiers == hotkey.modifiers else { continue }

            // 防抖检查 - 避免短时间内重复触发
            if currentTime - hotkey.lastTriggerTime < hotkeyDebounceInterval {
                continue
            }

            // 更新最后触发时间
            var updatedHotkey = hotkey
            updatedHotkey = HotkeyInfo(
                keyCode: hotkey.keyCode,
                modifiers: hotkey.modifiers,
                ignoreRepeat: hotkey.ignoreRepeat,
                lastTriggerTime: currentTime,
                carbonHotKeyRef: hotkey.carbonHotKeyRef,
                hotKeyID: hotkey.hotKeyID
            )
            registeredHotkeys[action] = updatedHotkey

            NSLog("ClipboardPlugin: Hotkey triggered for action: %@, app: %@", action, currentFrontApp ?? "unknown")

            // 通知Flutter端
            DispatchQueue.main.async { [weak self] in
                self?.channel?.invokeMethod("onHotkeyPressed", arguments: ["action": action])
            }

            // 找到匹配的快捷键后立即退出循环
            break
        }
    }

    /// 解析按键代码
    private func parseKeyCode(from components: [String]) -> UInt16? {
        let keyComponent = components.last?.lowercased()

        // 特殊处理功能键
        if keyComponent?.hasPrefix("f") == true {
            let keyNumber = keyComponent?.replacingOccurrences(of: "f", with: "")
            if let num = Int(keyNumber ?? ""), num >= 1 && num <= 12 {
                switch num {
                case 1: return 0x7A
                case 2: return 0x78
                case 3: return 0x63
                case 4: return 0x76
                case 5: return 0x60
                case 6: return 0x61
                case 7: return 0x62
                case 8: return 0x64
                case 9: return 0x65
                case 10: return 0x6D
                case 11: return 0x67
                case 12: return 0x6F
                default: break
                }
            }
        }

        return keyMappingTable.first(where: { $0.value == keyComponent })?.key
    }

    /// 解析修饰键
    private func parseModifiers(from components: [String]) -> NSEvent.ModifierFlags {
        var modifiers: NSEvent.ModifierFlags = []

        for component in components {
            switch component.lowercased() {
            case "cmd", "command": modifiers.insert(.command)
            case "shift": modifiers.insert(.shift)
            case "option", "alt": modifiers.insert(.option)
            case "control", "ctrl": modifiers.insert(.control)
            default: break
            }
        }

        return modifiers
    }

    // MARK: - 开机自启动功能

    /// 检查是否启用了开机自启动
    private func isAutostartEnabled(result: @escaping FlutterResult) {
        if #available(macOS 13.0, *) {
            let status = SMAppService.mainApp.status
            result(status == .enabled)
            return
        }
        // 旧版系统回退到 LaunchAgents 检查
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.example.clip_flow"
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let launchAgentsPath = homeDirectory.appendingPathComponent("Library/LaunchAgents")
        let plistPath = launchAgentsPath.appendingPathComponent("\(bundleIdentifier).plist")
        let isEnabled = FileManager.default.fileExists(atPath: plistPath.path)
        result(isEnabled)
    }

    /// 启用开机自启动
    private func enableAutostart(result: @escaping FlutterResult) {
        if #available(macOS 13.0, *) {
            do {
                try SMAppService.mainApp.register()
                result(true)
                return
            } catch {
                NSLog("SMAppService register failed: %@", error.localizedDescription)
                result(
                    FlutterError(
                        code: "SM_REGISTER_FAILED", message: error.localizedDescription,
                        details: nil))
                return
            }
        }
        // 旧版系统回退到 LaunchAgents
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.example.clip_flow"
        let appPath = Bundle.main.bundlePath
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let launchAgentsPath = homeDirectory.appendingPathComponent("Library/LaunchAgents")
        do {
            try FileManager.default.createDirectory(
                at: launchAgentsPath, withIntermediateDirectories: true, attributes: nil)
        } catch {
            NSLog("创建 LaunchAgents 目录失败: %@", error.localizedDescription)
            result(
                FlutterError(
                    code: "LAUNCH_AGENTS_DIR_FAILED", message: error.localizedDescription,
                    details: nil))
            return
        }
        let plistPath = launchAgentsPath.appendingPathComponent("\(bundleIdentifier).plist")
        let plistContent = """
            <?xml version=\"1.0\" encoding=\"UTF-8\"?>
            <!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
            <plist version=\"1.0\">
            <dict>
                <key>Label</key>
                <string>\(bundleIdentifier)</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(appPath)/Contents/MacOS/clip_flow</string>
                    <string>--hidden</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>KeepAlive</key>
                <false/>
            </dict>
            </plist>
            """
        do {
            try plistContent.write(to: plistPath, atomically: true, encoding: .utf8)
            let task = Process()
            task.launchPath = "/bin/launchctl"
            task.arguments = ["load", plistPath.path]
            task.launch()
            task.waitUntilExit()
            if task.terminationStatus == 0 {
                result(true)
            } else {
                result(
                    FlutterError(
                        code: "LAUNCHCTL_LOAD_FAILED", message: "launchctl load failed",
                        details: task.terminationStatus))
            }
        } catch {
            NSLog("创建开机自启动配置失败: %@", error.localizedDescription)
            result(
                FlutterError(
                    code: "CREATE_PLIST_FAILED", message: error.localizedDescription, details: nil))
        }
    }

    // MARK: - Files & Folders 权限：安全书签

    /// 让用户选择目录并创建持久化安全书签（需要 entitlements: app-scope bookmarks）
    private func pickDirectoryForBookmark(call: FlutterMethodCall, result: @escaping FlutterResult)
    {
        guard let args = call.arguments as? [String: Any],
            let key = args["key"] as? String
        else {
            result(FlutterError(code: "INVALID_ARGUMENT", message: "Missing 'key'", details: nil))
            return
        }
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "选择"
            panel.message = "请选择需要授权访问的文件夹"
            let response = panel.runModal()
            if response == .OK, let url = panel.url {
                do {
                    let bookmark = try url.bookmarkData(
                        options: [.withSecurityScope], includingResourceValuesForKeys: nil,
                        relativeTo: nil)
                    UserDefaults.standard.set(bookmark, forKey: "bookmark.\(key)")
                    UserDefaults.standard.synchronize()
                    result(["key": key, "path": url.path])
                } catch {
                    result(
                        FlutterError(
                            code: "BOOKMARK_FAILED", message: error.localizedDescription,
                            details: nil))
                }
            } else {
                result(nil)
            }
        }
    }

    /// 开始访问指定安全书签（解析并 startAccessingSecurityScopedResource）
    private func startBookmarkAccess(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
            let key = args["key"] as? String
        else {
            result(FlutterError(code: "INVALID_ARGUMENT", message: "Missing 'key'", details: nil))
            return
        }
        guard let data = UserDefaults.standard.data(forKey: "bookmark.\(key)") else {
            result(
                FlutterError(
                    code: "BOOKMARK_NOT_FOUND", message: "Bookmark not found for key: \(key)",
                    details: nil))
            return
        }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil,
                bookmarkDataIsStale: &isStale)
            if isStale {
                let newData = try url.bookmarkData(
                    options: [.withSecurityScope], includingResourceValuesForKeys: nil,
                    relativeTo: nil)
                UserDefaults.standard.set(newData, forKey: "bookmark.\(key)")
            }
            if url.startAccessingSecurityScopedResource() {
                accessingBookmarks[key] = url
                result(["key": key, "path": url.path])
            } else {
                result(
                    FlutterError(
                        code: "BOOKMARK_ACCESS_DENIED",
                        message: "Failed to start accessing bookmark for key: \(key)", details: nil)
                )
            }
        } catch {
            result(
                FlutterError(
                    code: "BOOKMARK_RESOLVE_FAILED", message: error.localizedDescription,
                    details: nil))
        }
    }

    /// 停止访问指定安全书签
    private func stopBookmarkAccess(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
            let key = args["key"] as? String
        else {
            result(FlutterError(code: "INVALID_ARGUMENT", message: "Missing 'key'", details: nil))
            return
        }
        if let url = accessingBookmarks.removeValue(forKey: key) {
            url.stopAccessingSecurityScopedResource()
            result(true)
        } else {
            result(false)
        }
    }

    /// 删除已保存的安全书签
    private func removeBookmark(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
            let key = args["key"] as? String
        else {
            result(FlutterError(code: "INVALID_ARGUMENT", message: "Missing 'key'", details: nil))
            return
        }
        if let url = accessingBookmarks.removeValue(forKey: key) {
            url.stopAccessingSecurityScopedResource()
        }
        UserDefaults.standard.removeObject(forKey: "bookmark.\(key)")
        result(true)
    }

    /// 禁用开机自启动
    private func disableAutostart(result: @escaping FlutterResult) {
        if #available(macOS 13.0, *) {
            do {
                try SMAppService.mainApp.unregister()
                result(true)
                return
            } catch {
                NSLog("SMAppService unregister failed: %@", error.localizedDescription)
                result(
                    FlutterError(
                        code: "SM_UNREGISTER_FAILED", message: error.localizedDescription,
                        details: nil))
                return
            }
        }
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.example.clip_flow"
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let launchAgentsPath = homeDirectory.appendingPathComponent("Library/LaunchAgents")
        let plistPath = launchAgentsPath.appendingPathComponent("\(bundleIdentifier).plist")
        if FileManager.default.fileExists(atPath: plistPath.path) {
            let task = Process()
            task.launchPath = "/bin/launchctl"
            task.arguments = ["unload", plistPath.path]
            task.launch()
            task.waitUntilExit()
            do {
                try FileManager.default.removeItem(at: plistPath)
                result(true)
            } catch {
                NSLog("删除开机自启动配置失败: %@", error.localizedDescription)
                result(
                    FlutterError(
                        code: "REMOVE_PLIST_FAILED", message: error.localizedDescription,
                        details: nil))
            }
        } else {
            result(true)
        }
    }

    /// 设置开发模式
    private func setDeveloperMode(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let enabled = args["enabled"] as? Bool else {
            result(FlutterError(code: "INVALID_ARGUMENT", message: "Missing enabled parameter", details: nil))
            return
        }

        developerModeEnabled = enabled
        NSLog("ClipboardPlugin: Developer mode \(enabled ? "enabled" : "disabled")")
        result(true)
    }

    /// 获取当前应用信息
    private func getCurrentApp(result: @escaping FlutterResult) {
        updateCurrentApp()

        let appInfo: [String: Any] = [
            "bundleId": currentFrontApp ?? "",
            "appName": getAppNameFromBundleId(currentFrontApp ?? ""),
            "appType": currentFrontApp != nil ? getAppType(currentFrontApp!) : "unknown",
            "developerMode": developerModeEnabled,
            "isDevelopmentApp": currentFrontApp != nil ? isDevelopmentApp(currentFrontApp!) : false,
            "isDesignApp": currentFrontApp != nil ? isDesignApp(currentFrontApp!) : false,
        ]

        result(appInfo)
    }

    /// 获取应用名称
    private func getAppNameFromBundleId(_ bundleId: String) -> String {
        let workspace = NSWorkspace.shared
        if let appUrl = workspace.urlForApplication(withBundleIdentifier: bundleId) {
            return appUrl.deletingPathExtension().lastPathComponent
        }
        return bundleId
    }

    /// 获取快捷键统计信息
    private func getHotkeyStats(result: @escaping FlutterResult) {
        // 创建一个简化的动作列表，因为Swift端无法直接访问Dart的枚举
        let supportedActions: [String] = [
            "toggleWindow", "quickPaste", "showHistory", "clearHistory",
            "search", "performOCR", "toggleMonitoring"
        ]

        let stats: [String: Any] = [
            "registeredHotkeys": registeredHotkeys.count,
            "systemHotkeys": systemHotkeysCache.count,
            "developerMode": developerModeEnabled,
            "currentApp": currentFrontApp ?? "",
            "debounceInterval": hotkeyDebounceInterval,
            "appCheckInterval": appCheckInterval,
            "supportedActions": supportedActions,
        ]

        result(stats)
    }

    /// 获取物理屏幕尺寸
    private func getPhysicalScreenSize(result: @escaping FlutterResult) {
        // 获取主屏幕
        guard let mainScreen = NSScreen.main else {
            result(FlutterError(code: "SCREEN_NOT_FOUND", message: "Main screen not found", details: nil))
            return
        }

        // 获取屏幕的物理尺寸
        let screenFrame = mainScreen.frame
        let screenVisibleFrame = mainScreen.visibleFrame

        // 获取屏幕分辨率
        let screenScale = mainScreen.backingScaleFactor
        let physicalWidth = screenFrame.width * screenScale
        let physicalHeight = screenFrame.height * screenScale

        // 获取屏幕的物理尺寸（毫米）
        let deviceDescription = mainScreen.deviceDescription
        let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        var physicalSize: CGSize = .zero

        print("📏 [getPhysicalScreenSize] 开始获取物理屏幕尺寸")
        print("📏 [getPhysicalScreenSize] screenNumber: \(screenNumber?.stringValue ?? "nil")")

        if let screenNumberValue = screenNumber {
            let displayID = CGDirectDisplayID(screenNumberValue.uint32Value)
            print("📏 [getPhysicalScreenSize] displayID: \(displayID)")

            // 获取显示器物理尺寸
            physicalSize = CGDisplayScreenSize(displayID)
            print("📏 [getPhysicalScreenSize] CGDisplayScreenSize 返回: \(physicalSize)")
            print("📏 [getPhysicalScreenSize] 物理宽度: \(physicalSize.width)mm, 物理高度: \(physicalSize.height)mm")
        } else {
            print("⚠️ [getPhysicalScreenSize] 无法获取 screenNumber")
        }

        // 获取显示器信息
        let displayInfo: [String: Any] = [
            "screenWidth": screenFrame.width,
            "screenHeight": screenFrame.height,
            "visibleWidth": screenVisibleFrame.width,
            "visibleHeight": screenVisibleFrame.height,
            "scaleFactor": screenScale,
            "physicalWidth": physicalWidth,
            "physicalHeight": physicalHeight,
            "physicalWidthMM": physicalSize.width,
            "physicalHeightMM": physicalSize.height,
            "diagonalMM": sqrt(pow(physicalSize.width, 2) + pow(physicalSize.height, 2)),
            "colorSpace": mainScreen.colorSpace?.localizedName ?? "unknown",
            "isMain": mainScreen == NSScreen.main
        ]

        // 如果有多个显示器，也返回所有显示器的信息
        var allScreens: [[String: Any]] = []

        print("📏 [getPhysicalScreenSize] 总显示器数量: \(NSScreen.screens.count)")
        var screenIndex = 0

        for screen in NSScreen.screens {
            let screenFrame = screen.frame
            let screenVisibleFrame = screen.visibleFrame
            let screenScale = screen.backingScaleFactor
            let physicalWidth = screenFrame.width * screenScale
            let physicalHeight = screenFrame.height * screenScale

            // 获取物理尺寸
            let deviceDescription = screen.deviceDescription
            let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            var physicalSize: CGSize = .zero

            print("📏 [getPhysicalScreenSize] 处理显示器 \(screenIndex):")
            print("   - 逻辑尺寸: \(screenFrame.width) x \(screenFrame.height)")
            print("   - 缩放因子: \(screenScale)")
            print("   - 物理像素: \(physicalWidth) x \(physicalHeight)")
            print("   - screenNumber: \(screenNumber?.stringValue ?? "nil")")

            if let screenNumberValue = screenNumber {
                let displayID = CGDirectDisplayID(screenNumberValue.uint32Value)
                print("   - displayID: \(displayID)")
                physicalSize = CGDisplayScreenSize(displayID)
                print("   - 物理尺寸: \(physicalSize.width)mm x \(physicalSize.height)mm")
            } else {
                print("   - ⚠️ 无法获取 screenNumber")
            }

            screenIndex += 1

            let screenInfo: [String: Any] = [
                "screenWidth": screenFrame.width,
                "screenHeight": screenFrame.height,
                "visibleWidth": screenVisibleFrame.width,
                "visibleHeight": screenVisibleFrame.height,
                "scaleFactor": screenScale,
                "physicalWidth": physicalWidth,
                "physicalHeight": physicalHeight,
                "physicalWidthMM": physicalSize.width,
                "physicalHeightMM": physicalSize.height,
                "diagonalMM": sqrt(pow(physicalSize.width, 2) + pow(physicalSize.height, 2)),
                "colorSpace": screen.colorSpace?.localizedName ?? "unknown",
                "isMain": screen == NSScreen.main
            ]

            allScreens.append(screenInfo)
        }

        let resultData: [String: Any] = [
            "mainDisplay": displayInfo,
            "allDisplays": allScreens,
            "displayCount": NSScreen.screens.count
        ]

        print("📏 [getPhysicalScreenSize] 结果总结:")
        print("   - 主显示器物理尺寸: \(physicalSize.width)mm x \(physicalSize.height)mm")
        print("   - 对角线长度: \(sqrt(pow(physicalSize.width, 2) + pow(physicalSize.height, 2)))mm")
        print("   - 总显示器数量: \(NSScreen.screens.count)")
        print("📏 [getPhysicalScreenSize] 完成")

        result(resultData)
    }

    /// 检测是否是登录启动（用于 SMAppService 场景）
    /// 通过系统运行时间判断：如果系统启动时间小于120秒，认为是登录启动
    private func isLoginLaunch(result: @escaping FlutterResult) {
        let uptime = ProcessInfo.processInfo.systemUptime
        // 如果系统运行时间小于120秒，认为是登录时的自动启动
        let isLoginLaunch = uptime < 120

        NSLog("ClipboardPlugin: isLoginLaunch check - uptime: %.1f seconds, isLoginLaunch: %@",
              uptime, isLoginLaunch ? "true" : "false")

        result([
            "isLoginLaunch": isLoginLaunch,
            "systemUptime": uptime
        ])
    }
}

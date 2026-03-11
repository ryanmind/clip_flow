import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  // 当最后一个窗口被关闭时，不自动终止应用，以支持最小化到托盘的常驻运行
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  // 处理程序坞图标点击 - 当窗口隐藏时唤起窗口
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    // 如果没有可见窗口，显示主窗口
    if !flag {
      if let window = mainFlutterWindow {
        window.makeKeyAndOrderFront(self)
        NSApp.activate(ignoringOtherApps: true)
      }
    }
    return true
  }
  
  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
  }
  
  private func getClipboardImage(result: @escaping FlutterResult) {
    let pasteboard = NSPasteboard.general
    
    // 检查是否有图片数据
    if let imageData = pasteboard.data(forType: .png) {
      result(FlutterStandardTypedData(bytes: imageData))
    } else if let imageData = pasteboard.data(forType: NSPasteboard.PasteboardType("public.jpeg")) {
      result(FlutterStandardTypedData(bytes: imageData))
    } else if let imageData = pasteboard.data(forType: .tiff) {
      result(FlutterStandardTypedData(bytes: imageData))
    } else {
      result(nil)
    }
  }
  
  private func setClipboardImage(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let imageData = args["imageData"] as? FlutterStandardTypedData else {
      result(FlutterError(code: "INVALID_ARGUMENT", message: "Invalid image data", details: nil))
      return
    }
    
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    
    let data = imageData.data
    pasteboard.setData(data, forType: .png)
    
    result(true)
  }
  
  private func getSourceApp(result: @escaping FlutterResult) {
    // 获取当前活跃的应用程序
    if let frontmostApp = NSWorkspace.shared.frontmostApplication {
      result(frontmostApp.localizedName)
    } else {
      result(nil)
    }
  }
}

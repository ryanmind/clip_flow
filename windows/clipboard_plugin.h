#ifndef FLUTTER_PLUGIN_CLIPBOARD_PLUGIN_H_
#define FLUTTER_PLUGIN_CLIPBOARD_PLUGIN_H_

#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <memory>
#include <optional>
#include <string>

namespace clipboard_plugin {

class ClipboardPlugin : public flutter::Plugin {
  public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  explicit ClipboardPlugin(flutter::PluginRegistrarWindows* registrar);

  virtual ~ClipboardPlugin();

  // Disallow copy and assign.
  ClipboardPlugin(const ClipboardPlugin&) = delete;
  ClipboardPlugin& operator=(const ClipboardPlugin&) = delete;

 private:
  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Method implementations
  void GetClipboardFormats(
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void GetClipboardType(
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  
  void GetClipboardSequence(
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  
  void GetClipboardFilePaths(
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  
  void GetClipboardImageData(
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  
  void PerformOCR(
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
  OnListen(
      const flutter::EncodableValue* arguments,
      std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events);

  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
  OnCancel(const flutter::EncodableValue* arguments);

  std::optional<LRESULT> HandleWindowProc(HWND hwnd,
                                          UINT message,
                                          WPARAM wparam,
                                          LPARAM lparam);

  bool StartClipboardMonitoring();
  void StopClipboardMonitoring();
  void EmitClipboardEvent(DWORD sequence);

  // Helper methods
  std::string DetectFileType(const std::string& path);
  std::string DetectTextType(const std::string& text);
  bool IsColorValue(const std::string& text);
  bool IsURL(const std::string& text);
  bool IsEmail(const std::string& text);
  bool IsFilePath(const std::string& text);
  bool IsJSON(const std::string& text);
  bool IsXMLOrHTML(const std::string& text);

  flutter::PluginRegistrarWindows* registrar_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>>
      event_channel_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> event_sink_;
  HWND window_handle_ = nullptr;
  int window_proc_delegate_id_ = 0;
  bool is_monitoring_ = false;
  DWORD last_emitted_sequence_ = 0;
};

}  // namespace clipboard_plugin

#endif  // FLUTTER_PLUGIN_CLIPBOARD_PLUGIN_H_

#include "clipboard_plugin.h"
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <shlobj.h>
#include <string>
#include <vector>
#include <memory>
#include <algorithm>
#include <cctype>
#include <chrono>
#include <winrt/base.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Graphics.Imaging.h>
#include <winrt/Windows.Media.Ocr.h>
#include <winrt/Windows.Storage.Streams.h>

namespace clipboard_plugin {

// static
void ClipboardPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "clipboard_service",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<ClipboardPlugin>(registrar);

  plugin->event_channel_ =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          registrar->messenger(), "clipboard_events",
          &flutter::StandardMethodCodec::GetInstance());

  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto& call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  plugin->event_channel_->SetStreamHandler(std::make_unique<
      flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
      [plugin_pointer = plugin.get()](
          const flutter::EncodableValue* arguments,
          std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events) {
        return plugin_pointer->OnListen(arguments, std::move(events));
      },
      [plugin_pointer = plugin.get()](const flutter::EncodableValue* arguments) {
        return plugin_pointer->OnCancel(arguments);
      }));

  registrar->AddPlugin(std::move(plugin));
}

ClipboardPlugin::ClipboardPlugin(flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar) {}

ClipboardPlugin::~ClipboardPlugin() {
  StopClipboardMonitoring();
}

std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
ClipboardPlugin::OnListen(
    const flutter::EncodableValue* arguments,
    std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events) {
  (void)arguments;
  event_sink_ = std::move(events);

  if (!StartClipboardMonitoring()) {
    event_sink_.reset();
    return std::make_unique<flutter::StreamHandlerError<flutter::EncodableValue>>(
        "clipboard_monitor_error",
        "Failed to start clipboard monitoring on Windows",
        nullptr);
  }

  return nullptr;
}

std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
ClipboardPlugin::OnCancel(const flutter::EncodableValue* arguments) {
  (void)arguments;
  StopClipboardMonitoring();
  event_sink_.reset();
  return nullptr;
}

bool ClipboardPlugin::StartClipboardMonitoring() {
  if (is_monitoring_) {
    return true;
  }

  auto* view = registrar_ != nullptr ? registrar_->GetView() : nullptr;
  if (view == nullptr) {
    return false;
  }

  window_handle_ = view->GetNativeWindow();
  if (window_handle_ == nullptr) {
    return false;
  }

  if (window_proc_delegate_id_ == 0) {
    window_proc_delegate_id_ = registrar_->RegisterTopLevelWindowProcDelegate(
        [this](HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
          return HandleWindowProc(hwnd, message, wparam, lparam);
        });
  }

  if (!AddClipboardFormatListener(window_handle_)) {
    if (window_proc_delegate_id_ != 0) {
      registrar_->UnregisterTopLevelWindowProcDelegate(window_proc_delegate_id_);
      window_proc_delegate_id_ = 0;
    }
    window_handle_ = nullptr;
    return false;
  }

  last_emitted_sequence_ = GetClipboardSequenceNumber();
  is_monitoring_ = true;
  return true;
}

void ClipboardPlugin::StopClipboardMonitoring() {
  if (window_handle_ != nullptr) {
    RemoveClipboardFormatListener(window_handle_);
    window_handle_ = nullptr;
  }

  if (window_proc_delegate_id_ != 0 && registrar_ != nullptr) {
    registrar_->UnregisterTopLevelWindowProcDelegate(window_proc_delegate_id_);
    window_proc_delegate_id_ = 0;
  }

  is_monitoring_ = false;
}

std::optional<LRESULT> ClipboardPlugin::HandleWindowProc(HWND hwnd,
                                                         UINT message,
                                                         WPARAM wparam,
                                                         LPARAM lparam) {
  (void)hwnd;
  (void)wparam;
  (void)lparam;

  if (!is_monitoring_ || event_sink_ == nullptr) {
    return std::nullopt;
  }

  if (message == WM_CLIPBOARDUPDATE) {
    const DWORD sequence = GetClipboardSequenceNumber();
    if (sequence != last_emitted_sequence_) {
      EmitClipboardEvent(sequence);
    }
  }

  return std::nullopt;
}

void ClipboardPlugin::EmitClipboardEvent(DWORD sequence) {
  if (event_sink_ == nullptr) {
    return;
  }

  last_emitted_sequence_ = sequence;
  const auto now = std::chrono::system_clock::now();
  const auto timestamp = std::chrono::duration_cast<std::chrono::milliseconds>(
      now.time_since_epoch()).count();

  flutter::EncodableMap event;
  event[flutter::EncodableValue("sequence")] =
      flutter::EncodableValue(static_cast<int64_t>(sequence));
  event[flutter::EncodableValue("timestamp")] =
      flutter::EncodableValue(static_cast<int64_t>(timestamp));
  event[flutter::EncodableValue("platform")] =
      flutter::EncodableValue("windows");
  event[flutter::EncodableValue("source")] =
      flutter::EncodableValue("wm_clipboardupdate");
  event[flutter::EncodableValue("monitoringIntervalMs")] =
      flutter::EncodableValue(0);

  event_sink_->Success(flutter::EncodableValue(event));
}

void ClipboardPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {

  if (method_call.method_name().compare("getClipboardFormats") == 0) {
    GetClipboardFormats(std::move(result));
  } else if (method_call.method_name().compare("getClipboardType") == 0) {
    GetClipboardType(std::move(result));
  } else if (method_call.method_name().compare("getClipboardSequence") == 0) {
    GetClipboardSequence(std::move(result));
  } else if (method_call.method_name().compare("getClipboardFilePaths") == 0) {
    GetClipboardFilePaths(std::move(result));
  } else if (method_call.method_name().compare("getClipboardImageData") == 0) {
    GetClipboardImageData(std::move(result));
  } else if (method_call.method_name().compare("performOCR") == 0) {
    PerformOCR(std::move(result));
  } else {
    result->NotImplemented();
  }
}

void ClipboardPlugin::GetClipboardFormats(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {

  if (!OpenClipboard(nullptr)) {
    result->Error("CLIPBOARD_ERROR", "Failed to open clipboard");
    return;
  }

  flutter::EncodableMap formats_data;

  // 添加序列号和时间戳
  DWORD sequence = GetClipboardSequenceNumber();
  auto now = std::chrono::system_clock::now();
  auto timestamp = std::chrono::duration_cast<std::chrono::milliseconds>(
      now.time_since_epoch()).count();

  formats_data[flutter::EncodableValue("sequence")] = flutter::EncodableValue(static_cast<int64_t>(sequence));
  formats_data[flutter::EncodableValue("timestamp")] = flutter::EncodableValue(static_cast<int64_t>(timestamp));

  // 检查并收集所有可用格式

  // RTF 格式
  if (IsClipboardFormatAvailable(RegisterClipboardFormatW(L"Rich Text Format"))) {
    HANDLE hData = GetClipboardData(RegisterClipboardFormatW(L"Rich Text Format"));
    if (hData != nullptr) {
      char* pszText = static_cast<char*>(GlobalLock(hData));
      if (pszText != nullptr) {
        std::string rtfText(pszText);
        formats_data[flutter::EncodableValue("rtf")] = flutter::EncodableValue(rtfText);
        GlobalUnlock(hData);
      }
    }
  }

  // HTML 格式
  if (IsClipboardFormatAvailable(RegisterClipboardFormatW(L"HTML Format"))) {
    HANDLE hData = GetClipboardData(RegisterClipboardFormatW(L"HTML Format"));
    if (hData != nullptr) {
      char* pszText = static_cast<char*>(GlobalLock(hData));
      if (pszText != nullptr) {
        std::string htmlText(pszText);
        formats_data[flutter::EncodableValue("html")] = flutter::EncodableValue(htmlText);
        GlobalUnlock(hData);
      }
    }
  }

  // 文件格式
  if (IsClipboardFormatAvailable(CF_HDROP)) {
    HANDLE hData = GetClipboardData(CF_HDROP);
    if (hData != nullptr) {
      HDROP hDrop = static_cast<HDROP>(hData);
      UINT fileCount = DragQueryFileW(hDrop, 0xFFFFFFFF, nullptr, 0);

      std::vector<flutter::EncodableValue> file_paths;
      wchar_t filePath[MAX_PATH];

      for (UINT i = 0; i < fileCount; i++) {
        if (DragQueryFileW(hDrop, i, filePath, MAX_PATH)) {
          std::wstring ws(filePath);
          std::string path(ws.begin(), ws.end());
          file_paths.push_back(flutter::EncodableValue(path));
        }
      }

      if (!file_paths.empty()) {
        formats_data[flutter::EncodableValue("files")] = flutter::EncodableValue(file_paths);
      }
    }
  }

  // 图片格式 (DIB)
  if (IsClipboardFormatAvailable(CF_DIB)) {
    HANDLE hData = GetClipboardData(CF_DIB);
    if (hData != nullptr) {
      BITMAPINFO* pBitmapInfo = static_cast<BITMAPINFO*>(GlobalLock(hData));
      if (pBitmapInfo != nullptr) {
        SIZE_T dataSize = GlobalSize(hData);
        std::vector<uint8_t> image_data(dataSize);
        memcpy(image_data.data(), pBitmapInfo, dataSize);

        // 转换为 Flutter EncodableList
        std::vector<flutter::EncodableValue> image_vector;
        image_vector.reserve(image_data.size());
        for (const auto& byte : image_data) {
          image_vector.push_back(flutter::EncodableValue(static_cast<int>(byte)));
        }

        formats_data[flutter::EncodableValue("image")] = flutter::EncodableValue(image_vector);
        GlobalUnlock(hData);
      }
    }
  }

  // 文本格式 (Unicode)
  if (IsClipboardFormatAvailable(CF_UNICODETEXT)) {
    HANDLE hData = GetClipboardData(CF_UNICODETEXT);
    if (hData != nullptr) {
      wchar_t* pszText = static_cast<wchar_t*>(GlobalLock(hData));
      if (pszText != nullptr) {
        std::wstring ws(pszText);
        std::string text(ws.begin(), ws.end());
        formats_data[flutter::EncodableValue("text")] = flutter::EncodableValue(text);
        GlobalUnlock(hData);
      }
    }
  }
  // 备用文本格式 (ANSI)
  else if (IsClipboardFormatAvailable(CF_TEXT)) {
    HANDLE hData = GetClipboardData(CF_TEXT);
    if (hData != nullptr) {
      char* pszText = static_cast<char*>(GlobalLock(hData));
      if (pszText != nullptr) {
        std::string text(pszText);
        formats_data[flutter::EncodableValue("text")] = flutter::EncodableValue(text);
        GlobalUnlock(hData);
      }
    }
  }

  CloseClipboard();
  result->Success(flutter::EncodableValue(formats_data));
}

void ClipboardPlugin::GetClipboardType(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  
  if (!OpenClipboard(nullptr)) {
    result->Error("CLIPBOARD_ERROR", "Failed to open clipboard");
    return;
  }

  flutter::EncodableMap clipboard_info;
  
  // 优先检查 RTF 格式 (最高优先级)
  if (IsClipboardFormatAvailable(RegisterClipboardFormatW(L"Rich Text Format"))) {
    clipboard_info[flutter::EncodableValue("type")] = flutter::EncodableValue("text");
    clipboard_info[flutter::EncodableValue("hasData")] = flutter::EncodableValue(true);
    clipboard_info[flutter::EncodableValue("priority")] = flutter::EncodableValue(1);
  }
  // 检查 HTML 格式 (第二优先级)
  else if (IsClipboardFormatAvailable(RegisterClipboardFormatW(L"HTML Format"))) {
    clipboard_info[flutter::EncodableValue("type")] = flutter::EncodableValue("text");
    clipboard_info[flutter::EncodableValue("hasData")] = flutter::EncodableValue(true);
    clipboard_info[flutter::EncodableValue("priority")] = flutter::EncodableValue(2);
  }
  // 检查文件类型 (第三优先级)
  else if (IsClipboardFormatAvailable(CF_HDROP)) {
    HANDLE hData = GetClipboardData(CF_HDROP);
    if (hData != nullptr) {
      HDROP hDrop = static_cast<HDROP>(hData);
      UINT fileCount = DragQueryFileW(hDrop, 0xFFFFFFFF, nullptr, 0);
      
      if (fileCount > 0) {
        std::vector<flutter::EncodableValue> file_paths;
        wchar_t filePath[MAX_PATH];
        
        for (UINT i = 0; i < fileCount; i++) {
          if (DragQueryFileW(hDrop, i, filePath, MAX_PATH)) {
            std::wstring ws(filePath);
            std::string path(ws.begin(), ws.end());
            file_paths.push_back(flutter::EncodableValue(path));
          }
        }
        
        if (!file_paths.empty()) {
          std::string first_path = std::get<std::string>(file_paths[0]);
          
          clipboard_info[flutter::EncodableValue("type")] = flutter::EncodableValue("file");
          clipboard_info[flutter::EncodableValue("hasData")] = flutter::EncodableValue(true);
          clipboard_info[flutter::EncodableValue("primaryPath")] = flutter::EncodableValue(first_path);
          clipboard_info[flutter::EncodableValue("priority")] = flutter::EncodableValue(3);
        }
      }
    }
  }
  // 检查图片类型 (第四优先级)
  else if (IsClipboardFormatAvailable(CF_DIB) || IsClipboardFormatAvailable(CF_BITMAP)) {
    std::string image_format = "bitmap";
    if (IsClipboardFormatAvailable(CF_DIB)) {
      image_format = "dib";
    }
    
    clipboard_info[flutter::EncodableValue("type")] = flutter::EncodableValue("image");
    clipboard_info[flutter::EncodableValue("hasData")] = flutter::EncodableValue(true);
    clipboard_info[flutter::EncodableValue("priority")] = flutter::EncodableValue(4);
  }
  // 检查文本类型 (最低优先级)
    else if (IsClipboardFormatAvailable(CF_UNICODETEXT) || IsClipboardFormatAvailable(CF_TEXT)) {
    HANDLE hData = GetClipboardData(CF_UNICODETEXT);
    if (hData != nullptr) {
      wchar_t* pszText = static_cast<wchar_t*>(GlobalLock(hData));
      if (pszText != nullptr) {
        std::wstring ws(pszText);
        std::string text(ws.begin(), ws.end());
        
        clipboard_info[flutter::EncodableValue("type")] = flutter::EncodableValue("text");
        clipboard_info[flutter::EncodableValue("length")] = flutter::EncodableValue(static_cast<int>(text.length()));
        clipboard_info[flutter::EncodableValue("hasData")] = flutter::EncodableValue(true);
        clipboard_info[flutter::EncodableValue("priority")] = flutter::EncodableValue(5);
        
        GlobalUnlock(hData);
      }
    }
  }
  else {
    // 未知类型
    clipboard_info[flutter::EncodableValue("type")] = flutter::EncodableValue("unknown");
    clipboard_info[flutter::EncodableValue("priority")] = flutter::EncodableValue(99);
  }

  CloseClipboard();
  result->Success(flutter::EncodableValue(clipboard_info));
}

void ClipboardPlugin::GetClipboardSequence(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  DWORD sequence = GetClipboardSequenceNumber();
  result->Success(flutter::EncodableValue(static_cast<int64_t>(sequence)));
}

void ClipboardPlugin::GetClipboardFilePaths(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  
  if (!OpenClipboard(nullptr)) {
    result->Success(flutter::EncodableValue());
    return;
  }

  std::vector<flutter::EncodableValue> file_paths;
  
  if (IsClipboardFormatAvailable(CF_HDROP)) {
    HANDLE hData = GetClipboardData(CF_HDROP);
    if (hData != nullptr) {
      HDROP hDrop = static_cast<HDROP>(hData);
      UINT fileCount = DragQueryFileW(hDrop, 0xFFFFFFFF, nullptr, 0);
      
      wchar_t filePath[MAX_PATH];
      for (UINT i = 0; i < fileCount; i++) {
        if (DragQueryFileW(hDrop, i, filePath, MAX_PATH)) {
          std::wstring ws(filePath);
          std::string path(ws.begin(), ws.end());
          file_paths.push_back(flutter::EncodableValue(path));
        }
      }
    }
  }

  CloseClipboard();
  
  if (file_paths.empty()) {
    result->Success(flutter::EncodableValue());
  } else {
    result->Success(flutter::EncodableValue(file_paths));
  }
}

void ClipboardPlugin::GetClipboardImageData(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  
  if (!OpenClipboard(nullptr)) {
    result->Success(flutter::EncodableValue());
    return;
  }

  std::vector<uint8_t> image_data;
  
  if (IsClipboardFormatAvailable(CF_DIB)) {
    HANDLE hData = GetClipboardData(CF_DIB);
    if (hData != nullptr) {
      BITMAPINFO* pBitmapInfo = static_cast<BITMAPINFO*>(GlobalLock(hData));
      if (pBitmapInfo != nullptr) {
        SIZE_T dataSize = GlobalSize(hData);
        image_data.resize(dataSize);
        memcpy(image_data.data(), pBitmapInfo, dataSize);
        GlobalUnlock(hData);
      }
    }
  }

  CloseClipboard();
  
  if (image_data.empty()) {
    result->Success(flutter::EncodableValue());
  } else {
    result->Success(flutter::EncodableValue(image_data));
  }
}

std::string ClipboardPlugin::DetectFileType(const std::string& path) {
  // 获取文件扩展名
  size_t dot_pos = path.find_last_of('.');
  if (dot_pos == std::string::npos) {
    return "file";
  }
  
  std::string extension = path.substr(dot_pos + 1);
  std::transform(extension.begin(), extension.end(), extension.begin(), ::tolower);
  
  // 图片文件
  std::vector<std::string> image_extensions = {
    "png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "tif", "svg", "ico", "heic", "heif"
  };
  if (std::find(image_extensions.begin(), image_extensions.end(), extension) != image_extensions.end()) {
    return "image";
  }
  
  // 音频文件
  std::vector<std::string> audio_extensions = {
    "mp3", "wav", "aac", "flac", "ogg", "m4a", "wma", "aiff", "au"
  };
  if (std::find(audio_extensions.begin(), audio_extensions.end(), extension) != audio_extensions.end()) {
    return "audio";
  }
  
  // 视频文件
  std::vector<std::string> video_extensions = {
    "mp4", "avi", "mov", "wmv", "flv", "webm", "mkv", "m4v", "3gp", "ts"
  };
  if (std::find(video_extensions.begin(), video_extensions.end(), extension) != video_extensions.end()) {
    return "video";
  }
  
  // 文档文件
  std::vector<std::string> document_extensions = {
    "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf"
  };
  if (std::find(document_extensions.begin(), document_extensions.end(), extension) != document_extensions.end()) {
    return "document";
  }
  
  // 压缩文件
  std::vector<std::string> archive_extensions = {
    "zip", "rar", "7z", "tar", "gz", "bz2", "xz"
  };
  if (std::find(archive_extensions.begin(), archive_extensions.end(), extension) != archive_extensions.end()) {
    return "archive";
  }
  
  // 代码文件
  std::vector<std::string> code_extensions = {
    "cpp", "c", "h", "cs", "js", "ts", "py", "java", "go", "rs", "php", "rb", "kt", "dart"
  };
  if (std::find(code_extensions.begin(), code_extensions.end(), extension) != code_extensions.end()) {
    return "code";
  }
  
  return "file";
}

// 说明：细粒度文本类型判断现由 Dart 层负责；
// 原生实现保留但不在运行时使用，避免规则漂移。
std::string ClipboardPlugin::DetectTextType(const std::string& text) {
  std::string trimmed = text;
  // 简单的 trim 实现
  trimmed.erase(trimmed.begin(), std::find_if(trimmed.begin(), trimmed.end(), [](unsigned char ch) {
    return !std::isspace(ch);
  }));
  trimmed.erase(std::find_if(trimmed.rbegin(), trimmed.rend(), [](unsigned char ch) {
    return !std::isspace(ch);
  }).base(), trimmed.end());
  
  // 检查是否是颜色值
  if (IsColorValue(trimmed)) {
    return "color";
  }
  
  // 检查是否是 URL
  if (IsURL(trimmed)) {
    return "url";
  }
  
  // 检查是否是邮箱
  if (IsEmail(trimmed)) {
    return "email";
  }
  
  // 检查是否是文件路径
  if (IsFilePath(trimmed)) {
    return "path";
  }
  
  // 检查是否是 JSON
  if (IsJSON(trimmed)) {
    return "json";
  }
  
  // 检查是否是 XML/HTML
  if (IsXMLOrHTML(trimmed)) {
    return "markup";
  }
  
  return "plain";
}

// 说明：颜色值解析与规范化已迁移到 Dart 层的 ColorUtils；
// 本方法保留但不参与运行时分类。
bool ClipboardPlugin::IsColorValue(const std::string& text) {
  // 简单的十六进制颜色检查
  if (text.length() == 7 && text[0] == '#') {
    for (size_t i = 1; i < text.length(); i++) {
      char c = text[i];
      if (!((c >= '0' && c <= '9') || (c >= 'A' && c <= 'F') || (c >= 'a' && c <= 'f'))) {
        return false;
      }
    }
    return true;
  }
  
  // RGB 格式检查
  if (text.find("rgb(") == 0 || text.find("rgba(") == 0) {
    return true;
  }
  
  return false;
}

bool ClipboardPlugin::IsURL(const std::string& text) {
  return text.find("http://") == 0 || text.find("https://") == 0 || text.find("ftp://") == 0;
}

bool ClipboardPlugin::IsEmail(const std::string& text) {
  return text.find('@') != std::string::npos && text.find('.') != std::string::npos;
}

bool ClipboardPlugin::IsFilePath(const std::string& text) {
  return text.find("file://") == 0 || text.find('/') != std::string::npos || text.find('\\') != std::string::npos;
}

bool ClipboardPlugin::IsJSON(const std::string& text) {
  return (text.front() == '{' && text.back() == '}') || (text.front() == '[' && text.back() == ']');
}

bool ClipboardPlugin::IsXMLOrHTML(const std::string& text) {
  return text.find('<') != std::string::npos && text.find('>') != std::string::npos;
}

void ClipboardPlugin::PerformOCR(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  
  try {
    // 初始化 WinRT
    winrt::init_apartment();
    
    // 检查剪贴板是否包含图像
    if (!OpenClipboard(nullptr)) {
      result->Error("CLIPBOARD_ERROR", "Failed to open clipboard");
      return;
    }

    if (!IsClipboardFormatAvailable(CF_BITMAP) && !IsClipboardFormatAvailable(CF_DIB)) {
      CloseClipboard();
      result->Error("NO_IMAGE", "No image found in clipboard");
      return;
    }

    // 获取剪贴板图像数据
    HANDLE hData = GetClipboardData(CF_DIB);
    if (hData == nullptr) {
      CloseClipboard();
      result->Error("IMAGE_ERROR", "Failed to get image data from clipboard");
      return;
    }

    // 将 DIB 数据转换为 WinRT SoftwareBitmap
    LPBITMAPINFOHEADER lpbi = (LPBITMAPINFOHEADER)GlobalLock(hData);
    if (lpbi == nullptr) {
      CloseClipboard();
      result->Error("IMAGE_ERROR", "Failed to lock image data");
      return;
    }

    // 创建 OCR 引擎
    auto ocrEngine = winrt::Windows::Media::Ocr::OcrEngine::TryCreateFromUserProfileLanguages();
    if (ocrEngine == nullptr) {
      GlobalUnlock(hData);
      CloseClipboard();
      result->Error("OCR_ERROR", "Failed to create OCR engine");
      return;
    }

    // 计算图像数据大小
    DWORD dwBmpSize = lpbi->biSizeImage;
    if (dwBmpSize == 0) {
      dwBmpSize = (lpbi->biWidth * lpbi->biBitCount + 31) / 32 * 4 * lpbi->biHeight;
    }

    // 创建内存流
    auto stream = winrt::Windows::Storage::Streams::InMemoryRandomAccessStream();
    auto writer = winrt::Windows::Storage::Streams::DataWriter(stream);
    
    // 写入 BMP 文件头
    BITMAPFILEHEADER bmfh = {};
    bmfh.bfType = 0x4D42; // "BM"
    bmfh.bfSize = sizeof(BITMAPFILEHEADER) + lpbi->biSize + dwBmpSize;
    bmfh.bfOffBits = sizeof(BITMAPFILEHEADER) + lpbi->biSize;
    
    writer.WriteBytes(winrt::array_view<uint8_t const>(
      reinterpret_cast<uint8_t const*>(&bmfh), sizeof(BITMAPFILEHEADER)));
    
    // 写入 DIB 数据
    writer.WriteBytes(winrt::array_view<uint8_t const>(
      reinterpret_cast<uint8_t const*>(lpbi), lpbi->biSize + dwBmpSize));
    
    GlobalUnlock(hData);
    CloseClipboard();

    // 存储数据到流
    auto storeOperation = writer.StoreAsync();
    storeOperation.get();
    writer.DetachStream();
    
    // 从流创建 BitmapDecoder
    stream.Seek(0);
    auto decoder = winrt::Windows::Graphics::Imaging::BitmapDecoder::CreateAsync(stream).get();
    auto softwareBitmap = decoder.GetSoftwareBitmapAsync().get();

    // 执行 OCR
    auto ocrResult = ocrEngine.RecognizeAsync(softwareBitmap).get();
    
    // 提取文本
    std::string recognizedText;
    for (auto const& line : ocrResult.Lines()) {
      if (!recognizedText.empty()) {
        recognizedText += "\n";
      }
      recognizedText += winrt::to_string(line.Text());
    }

    // 返回结果
    flutter::EncodableMap ocr_result;
    ocr_result[flutter::EncodableValue("text")] = flutter::EncodableValue(recognizedText);
    ocr_result[flutter::EncodableValue("confidence")] = flutter::EncodableValue(1.0); // Windows OCR 不提供置信度
    
    result->Success(flutter::EncodableValue(ocr_result));
    
  } catch (winrt::hresult_error const& ex) {
    std::string error_message = "OCR failed: " + winrt::to_string(ex.message());
    result->Error("OCR_ERROR", error_message);
  } catch (std::exception const& ex) {
    std::string error_message = "OCR failed: " + std::string(ex.what());
    result->Error("OCR_ERROR", error_message);
  } catch (...) {
    result->Error("OCR_ERROR", "Unknown OCR error occurred");
  }
}

}  // namespace clipboard_plugin

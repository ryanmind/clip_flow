#include "clipboard_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <string>
#include <vector>
#include <memory>
#include <algorithm>
#include <cctype>
#include <fstream>
#include <sstream>
#include <tesseract/baseapi.h>
#include <leptonica/allheaders.h>
#include <gdk-pixbuf/gdk-pixbuf.h>

#define CLIPBOARD_PLUGIN(obj) \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), clipboard_plugin_get_type(), \
                               ClipboardPlugin))

struct _ClipboardPlugin {
  GObject parent_instance;
  GtkClipboard* clipboard;
  FlEventChannel* event_channel;
  gulong owner_change_handler_id;
  gint64 clipboard_sequence;
  gboolean is_listening;
};

G_DEFINE_TYPE(ClipboardPlugin, clipboard_plugin, g_object_get_type())

// Forward declarations
static void get_clipboard_formats(FlMethodCall* method_call);
static FlMethodErrorResponse* clipboard_events_listen_cb(
    FlEventChannel* channel,
    FlValue* args,
    gpointer user_data);
static FlMethodErrorResponse* clipboard_events_cancel_cb(
    FlEventChannel* channel,
    FlValue* args,
    gpointer user_data);
static void send_clipboard_event(ClipboardPlugin* plugin);
static void clipboard_owner_change_cb(GtkClipboard* clipboard,
                                      GdkEvent* event,
                                      gpointer user_data);
static void clipboard_plugin_handle_method_call(
    ClipboardPlugin* self,
    FlMethodCall* method_call);

static void clipboard_plugin_dispose(GObject* object) {
  ClipboardPlugin* self = CLIPBOARD_PLUGIN(object);
  if (self->clipboard != nullptr) {
    if (self->owner_change_handler_id != 0) {
      g_signal_handler_disconnect(self->clipboard, self->owner_change_handler_id);
      self->owner_change_handler_id = 0;
    }
    g_object_unref(self->clipboard);
    self->clipboard = nullptr;
  }
  if (self->event_channel != nullptr) {
    g_object_unref(self->event_channel);
    self->event_channel = nullptr;
  }
  G_OBJECT_CLASS(clipboard_plugin_parent_class)->dispose(object);
}

static void clipboard_plugin_class_init(ClipboardPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = clipboard_plugin_dispose;
}

static void clipboard_plugin_init(ClipboardPlugin* self) {
  self->clipboard = nullptr;
  self->event_channel = nullptr;
  self->owner_change_handler_id = 0;
  self->clipboard_sequence = 0;
  self->is_listening = FALSE;
}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                          gpointer user_data) {
  ClipboardPlugin* plugin = CLIPBOARD_PLUGIN(user_data);
  clipboard_plugin_handle_method_call(plugin, method_call);
}

void clipboard_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  ClipboardPlugin* plugin = CLIPBOARD_PLUGIN(
      g_object_new(clipboard_plugin_get_type(), nullptr));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel =
      fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
                            "clipboard_service",
                            FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method_call_cb,
                                            g_object_ref(plugin),
                                            g_object_unref);

  g_autoptr(FlStandardMethodCodec) event_codec = fl_standard_method_codec_new();
  plugin->event_channel = fl_event_channel_new(
      fl_plugin_registrar_get_messenger(registrar),
      "clipboard_events",
      FL_METHOD_CODEC(event_codec));
  fl_event_channel_set_stream_handlers(plugin->event_channel,
                                       clipboard_events_listen_cb,
                                       clipboard_events_cancel_cb,
                                       plugin,
                                       nullptr);

  plugin->clipboard = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
  if (plugin->clipboard != nullptr) {
    g_object_ref(plugin->clipboard);
    plugin->owner_change_handler_id = g_signal_connect(
        plugin->clipboard,
        "owner-change",
        G_CALLBACK(clipboard_owner_change_cb),
        plugin);
  }

  g_object_unref(plugin);
}

static void clipboard_owner_change_cb(GtkClipboard* clipboard,
                                      GdkEvent* event,
                                      gpointer user_data) {
  (void)clipboard;
  (void)event;
  ClipboardPlugin* plugin = CLIPBOARD_PLUGIN(user_data);
  plugin->clipboard_sequence++;
  if (plugin->is_listening) {
    send_clipboard_event(plugin);
  }
}

static FlMethodErrorResponse* clipboard_events_listen_cb(
    FlEventChannel* channel,
    FlValue* args,
    gpointer user_data) {
  (void)channel;
  (void)args;
  ClipboardPlugin* plugin = CLIPBOARD_PLUGIN(user_data);
  plugin->is_listening = TRUE;
  return nullptr;
}

static FlMethodErrorResponse* clipboard_events_cancel_cb(
    FlEventChannel* channel,
    FlValue* args,
    gpointer user_data) {
  (void)channel;
  (void)args;
  ClipboardPlugin* plugin = CLIPBOARD_PLUGIN(user_data);
  plugin->is_listening = FALSE;
  return nullptr;
}

static void send_clipboard_event(ClipboardPlugin* plugin) {
  if (plugin->event_channel == nullptr) {
    return;
  }

  g_autoptr(FlValue) event = fl_value_new_map();
  fl_value_set_string_take(
      event,
      "sequence",
      fl_value_new_int(plugin->clipboard_sequence));
  fl_value_set_string_take(
      event,
      "timestamp",
      fl_value_new_int(g_get_real_time() / 1000));
  fl_value_set_string_take(
      event,
      "platform",
      fl_value_new_string("linux"));
  fl_value_set_string_take(
      event,
      "source",
      fl_value_new_string("owner-change"));
  fl_value_set_string_take(
      event,
      "monitoringIntervalMs",
      fl_value_new_int(0));

  fl_event_channel_send(plugin->event_channel, event, nullptr, nullptr);
}

// Helper functions
static std::string detect_file_type(const std::string& path) {
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

static std::string trim(const std::string& str) {
  size_t first = str.find_first_not_of(' ');
  if (std::string::npos == first) {
    return str;
  }
  size_t last = str.find_last_not_of(' ');
  return str.substr(first, (last - first + 1));
}

// 说明：颜色值判断已迁移到 Dart 层的 ColorUtils；
// 本方法保留但不参与运行时分类。
static bool is_color_value(const std::string& text) {
  std::string trimmed = trim(text);
  
  // 十六进制颜色检查
  if (trimmed.length() == 7 && trimmed[0] == '#') {
    for (size_t i = 1; i < trimmed.length(); i++) {
      char c = trimmed[i];
      if (!((c >= '0' && c <= '9') || (c >= 'A' && c <= 'F') || (c >= 'a' && c <= 'f'))) {
        return false;
      }
    }
    return true;
  }
  
  // RGB 格式检查
  if (trimmed.find("rgb(") == 0 || trimmed.find("rgba(") == 0) {
    return true;
  }
  
  return false;
}

static bool is_url(const std::string& text) {
  return text.find("http://") == 0 || text.find("https://") == 0 || text.find("ftp://") == 0;
}

static bool is_email(const std::string& text) {
  return text.find('@') != std::string::npos && text.find('.') != std::string::npos;
}

static bool is_file_path(const std::string& text) {
  return text.find("file://") == 0 || text.find('/') != std::string::npos;
}

static bool is_json(const std::string& text) {
  std::string trimmed = trim(text);
  return (trimmed.front() == '{' && trimmed.back() == '}') || 
         (trimmed.front() == '[' && trimmed.back() == ']');
}

static bool is_xml_or_html(const std::string& text) {
  std::string trimmed = trim(text);
  return trimmed.front() == '<' && trimmed.back() == '>';
}

// 说明：细粒度文本分类由 Dart 层负责；
// 原生实现保留但不在运行时使用，避免双端规则漂移。
static std::string detect_text_type(const std::string& text) {
  std::string trimmed = trim(text);
  
  if (is_color_value(trimmed)) {
    return "color";
  }
  
  if (is_url(trimmed)) {
    return "url";
  }
  
  if (is_email(trimmed)) {
    return "email";
  }
  
  if (is_file_path(trimmed)) {
    return "path";
  }
  
  if (is_json(trimmed)) {
    return "json";
  }
  
  if (is_xml_or_html(trimmed)) {
    return "markup";
  }
  
  return "plain";
}

static void get_clipboard_type(FlMethodCall* method_call) {
  GtkClipboard* clipboard = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
  
  g_autoptr(FlValue) result_map = fl_value_new_map();
  
  // 优先检查 RTF 格式 (最高优先级)
  if (gtk_clipboard_wait_is_target_available(clipboard, gdk_atom_intern("text/rtf", FALSE))) {
    fl_value_set_string_take(result_map, "type", fl_value_new_string("text"));
    fl_value_set_string_take(result_map, "hasData", fl_value_new_bool(TRUE));
    fl_value_set_string_take(result_map, "priority", fl_value_new_int(1));
  }
  // 检查 HTML 格式 (第二优先级)
  else if (gtk_clipboard_wait_is_target_available(clipboard, gdk_atom_intern("text/html", FALSE))) {
    fl_value_set_string_take(result_map, "type", fl_value_new_string("text"));
    fl_value_set_string_take(result_map, "hasData", fl_value_new_bool(TRUE));
    fl_value_set_string_take(result_map, "priority", fl_value_new_int(2));
  }
  // 检查文件类型 (第三优先级) (text/uri-list)
  else if (gtk_clipboard_wait_is_target_available(clipboard, gdk_atom_intern("text/uri-list", FALSE))) {
    gchar* uris_text = gtk_clipboard_wait_for_text(clipboard);
    if (uris_text != nullptr) {
      std::string uris_str(uris_text);
      std::istringstream iss(uris_str);
      std::string line;
      std::vector<std::string> file_paths;
      
      while (std::getline(iss, line)) {
        if (!line.empty() && line.find("file://") == 0) {
          std::string path = line.substr(7); // Remove "file://"
          file_paths.push_back(path);
        }
      }
      
      if (!file_paths.empty()) {
        std::string first_path = file_paths[0];
        std::string file_type = detect_file_type(first_path);
        
        g_autoptr(FlValue) paths_list = fl_value_new_list();
        for (const auto& path : file_paths) {
          fl_value_append_take(paths_list, fl_value_new_string(path.c_str()));
        }
        
        fl_value_set_string_take(result_map, "type", fl_value_new_string("file"));
        fl_value_set_string_take(result_map, "content", paths_list);
        fl_value_set_string_take(result_map, "primaryPath", fl_value_new_string(first_path.c_str()));
        fl_value_set_string_take(result_map, "priority", fl_value_new_int(3));
      }
      
      g_free(uris_text);
    }
  }
  // 检查图片类型 (第四优先级)
  else if (gtk_clipboard_wait_is_image_available(clipboard)) {
    GdkPixbuf* pixbuf = gtk_clipboard_wait_for_image(clipboard);
    if (pixbuf != nullptr) {
      fl_value_set_string_take(result_map, "type", fl_value_new_string("image"));
      fl_value_set_string_take(result_map, "hasData", fl_value_new_bool(TRUE));
      fl_value_set_string_take(result_map, "priority", fl_value_new_int(4));
      
      g_object_unref(pixbuf);
    }
  }
  // 检查文本类型 (最低优先级)
  else if (gtk_clipboard_wait_is_text_available(clipboard)) {
    gchar* text = gtk_clipboard_wait_for_text(clipboard);
    if (text != nullptr) {
      std::string text_str(text);
      
      fl_value_set_string_take(result_map, "type", fl_value_new_string("text"));
      fl_value_set_string_take(result_map, "length", fl_value_new_int(text_str.length()));
      fl_value_set_string_take(result_map, "hasData", fl_value_new_bool(TRUE));
      fl_value_set_string_take(result_map, "priority", fl_value_new_int(5));
      
      g_free(text);
    }
  }
  else {
    // 未知类型
    fl_value_set_string_take(result_map, "type", fl_value_new_string("unknown"));
    fl_value_set_string_take(result_map, "priority", fl_value_new_int(99));
  }
  
  fl_method_call_respond_success(method_call, result_map, nullptr);
}

static void get_clipboard_sequence(ClipboardPlugin* self,
                                   FlMethodCall* method_call) {
  g_autoptr(FlValue) result = fl_value_new_int(self->clipboard_sequence);
  fl_method_call_respond_success(method_call, result, nullptr);
}

static void get_clipboard_file_paths(FlMethodCall* method_call) {
  GtkClipboard* clipboard = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
  
  if (gtk_clipboard_wait_is_target_available(clipboard, gdk_atom_intern("text/uri-list", FALSE))) {
    gchar* uris_text = gtk_clipboard_wait_for_text(clipboard);
    if (uris_text != nullptr) {
      std::string uris_str(uris_text);
      std::istringstream iss(uris_str);
      std::string line;
      
      g_autoptr(FlValue) paths_list = fl_value_new_list();
      
      while (std::getline(iss, line)) {
        if (!line.empty() && line.find("file://") == 0) {
          std::string path = line.substr(7); // Remove "file://"
          fl_value_append_take(paths_list, fl_value_new_string(path.c_str()));
        }
      }
      
      fl_method_call_respond_success(method_call, paths_list, nullptr);
      g_free(uris_text);
      return;
    }
  }
  
  fl_method_call_respond_success(method_call, nullptr, nullptr);
}

static void get_clipboard_image_data(FlMethodCall* method_call) {
  GtkClipboard* clipboard = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
  
  if (gtk_clipboard_wait_is_image_available(clipboard)) {
    GdkPixbuf* pixbuf = gtk_clipboard_wait_for_image(clipboard);
    if (pixbuf != nullptr) {
      gchar* buffer;
      gsize buffer_size;
      GError* error = nullptr;
      
      if (gdk_pixbuf_save_to_buffer(pixbuf, &buffer, &buffer_size, "png", &error, nullptr)) {
        g_autoptr(FlValue) result = fl_value_new_uint8_list(
            reinterpret_cast<const uint8_t*>(buffer), buffer_size);
        fl_method_call_respond_success(method_call, result, nullptr);
        g_free(buffer);
      } else {
        fl_method_call_respond_error(method_call, "IMAGE_ERROR", 
                                   error ? error->message : "Failed to save image", 
                                   nullptr, nullptr);
        if (error) g_error_free(error);
      }
      
      g_object_unref(pixbuf);
      return;
    }
  }
  
  fl_method_call_respond_success(method_call, nullptr, nullptr);
}

static void perform_ocr(FlMethodCall* method_call) {
  GtkClipboard* clipboard = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
  
  // 检查剪贴板是否包含图像
  if (!gtk_clipboard_wait_is_image_available(clipboard)) {
    fl_method_call_respond_error(method_call, "NO_IMAGE", 
                               "No image found in clipboard", 
                               nullptr, nullptr);
    return;
  }
  
  // 获取剪贴板图像
  GdkPixbuf* pixbuf = gtk_clipboard_wait_for_image(clipboard);
  if (pixbuf == nullptr) {
    fl_method_call_respond_error(method_call, "IMAGE_ERROR", 
                               "Failed to get image from clipboard", 
                               nullptr, nullptr);
    return;
  }
  
  try {
    // 初始化 Tesseract OCR 引擎
    tesseract::TessBaseAPI* ocr = new tesseract::TessBaseAPI();
    
    // 初始化 OCR 引擎，使用英文语言包
    if (ocr->Init(nullptr, "eng") != 0) {
      delete ocr;
      g_object_unref(pixbuf);
      fl_method_call_respond_error(method_call, "OCR_ERROR", 
                                 "Failed to initialize OCR engine", 
                                 nullptr, nullptr);
      return;
    }
    
    // 将 GdkPixbuf 转换为 Leptonica PIX 格式
    gint width = gdk_pixbuf_get_width(pixbuf);
    gint height = gdk_pixbuf_get_height(pixbuf);
    gint channels = gdk_pixbuf_get_n_channels(pixbuf);
    gint rowstride = gdk_pixbuf_get_rowstride(pixbuf);
    guchar* pixels = gdk_pixbuf_get_pixels(pixbuf);
    
    // 创建 PIX 对象
    PIX* pix = nullptr;
    if (channels == 3) {
      // RGB 图像
      pix = pixCreate(width, height, 24);
      if (pix != nullptr) {
        l_uint32* data = pixGetData(pix);
        for (int y = 0; y < height; y++) {
          for (int x = 0; x < width; x++) {
            guchar* pixel = pixels + y * rowstride + x * channels;
            l_uint32 val = (pixel[0] << 16) | (pixel[1] << 8) | pixel[2];
            SET_DATA_BYTE(data, y * width + x, val);
          }
        }
      }
    } else if (channels == 4) {
      // RGBA 图像，忽略 alpha 通道
      pix = pixCreate(width, height, 24);
      if (pix != nullptr) {
        l_uint32* data = pixGetData(pix);
        for (int y = 0; y < height; y++) {
          for (int x = 0; x < width; x++) {
            guchar* pixel = pixels + y * rowstride + x * channels;
            l_uint32 val = (pixel[0] << 16) | (pixel[1] << 8) | pixel[2];
            SET_DATA_BYTE(data, y * width + x, val);
          }
        }
      }
    }
    
    if (pix == nullptr) {
      delete ocr;
      g_object_unref(pixbuf);
      fl_method_call_respond_error(method_call, "IMAGE_ERROR", 
                                 "Failed to convert image format", 
                                 nullptr, nullptr);
      return;
    }
    
    // 设置图像到 OCR 引擎
    ocr->SetImage(pix);
    
    // 执行 OCR 识别
    char* recognized_text = ocr->GetUTF8Text();
    
    if (recognized_text == nullptr) {
      delete ocr;
      pixDestroy(&pix);
      g_object_unref(pixbuf);
      fl_method_call_respond_error(method_call, "OCR_ERROR", 
                                 "OCR recognition failed", 
                                 nullptr, nullptr);
      return;
    }
    
    // 创建返回结果
    g_autoptr(FlValue) result_map = fl_value_new_map();
    g_autoptr(FlValue) text_value = fl_value_new_string(recognized_text);
    g_autoptr(FlValue) confidence_value = fl_value_new_float(ocr->MeanTextConf() / 100.0);
    
    fl_value_set_string_take(result_map, "text", fl_value_ref(text_value));
    fl_value_set_string_take(result_map, "confidence", fl_value_ref(confidence_value));
    
    fl_method_call_respond_success(method_call, result_map, nullptr);
    
    // 清理资源
    delete[] recognized_text;
    delete ocr;
    pixDestroy(&pix);
    g_object_unref(pixbuf);
    
  } catch (const std::exception& e) {
    g_object_unref(pixbuf);
    std::string error_msg = "OCR failed: " + std::string(e.what());
    fl_method_call_respond_error(method_call, "OCR_ERROR", 
                               error_msg.c_str(), 
                               nullptr, nullptr);
  } catch (...) {
    g_object_unref(pixbuf);
    fl_method_call_respond_error(method_call, "OCR_ERROR", 
                               "Unknown OCR error occurred", 
                               nullptr, nullptr);
  }
}

static void get_clipboard_formats(FlMethodCall* method_call) {
  GtkClipboard* clipboard = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);

  g_autoptr(FlValue) result_map = fl_value_new_map();

  // 添加序列号和时间戳
  static gint64 last_sequence = 0;
  last_sequence++;
  gint64 timestamp = g_get_real_time() / 1000; // 转换为毫秒

  fl_value_set_string_take(result_map, "sequence", fl_value_new_int(last_sequence));
  fl_value_set_string_take(result_map, "timestamp", fl_value_new_int(timestamp));

  // 检查并收集所有可用格式

  // RTF 格式
  if (gtk_clipboard_wait_is_target_available(clipboard, gdk_atom_intern("text/rtf", FALSE))) {
    GtkSelectionData* selection_data = gtk_clipboard_wait_for_contents(clipboard, gdk_atom_intern("text/rtf", FALSE));
    if (selection_data != nullptr) {
      const guchar* data = gtk_selection_data_get_data(selection_data);
      gint length = gtk_selection_data_get_length(selection_data);
      if (data != nullptr && length > 0) {
        gchar* rtf_text = g_strndup((const gchar*)data, length);
        fl_value_set_string_take(result_map, "rtf", fl_value_new_string(rtf_text));
        g_free(rtf_text);
      }
      gtk_selection_data_free(selection_data);
    }
  }

  // HTML 格式
  if (gtk_clipboard_wait_is_target_available(clipboard, gdk_atom_intern("text/html", FALSE))) {
    GtkSelectionData* selection_data = gtk_clipboard_wait_for_contents(clipboard, gdk_atom_intern("text/html", FALSE));
    if (selection_data != nullptr) {
      const guchar* data = gtk_selection_data_get_data(selection_data);
      gint length = gtk_selection_data_get_length(selection_data);
      if (data != nullptr && length > 0) {
        gchar* html_text = g_strndup((const gchar*)data, length);
        fl_value_set_string_take(result_map, "html", fl_value_new_string(html_text));
        g_free(html_text);
      }
      gtk_selection_data_free(selection_data);
    }
  }

  // 文件格式
  if (gtk_clipboard_wait_is_target_available(clipboard, gdk_atom_intern("text/uri-list", FALSE))) {
    GtkSelectionData* selection_data = gtk_clipboard_wait_for_contents(clipboard, gdk_atom_intern("text/uri-list", FALSE));
    if (selection_data != nullptr) {
      const guchar* data = gtk_selection_data_get_data(selection_data);
      gint length = gtk_selection_data_get_length(selection_data);
      if (data != nullptr && length > 0) {
        gchar* uris_text = g_strndup((const gchar*)data, length);
        std::string uris_str(uris_text);
        std::istringstream iss(uris_str);
        std::string line;
        g_autoptr(FlValue) paths_list = fl_value_new_list();

        while (std::getline(iss, line)) {
          if (!line.empty() && line.find("file://") == 0) {
            std::string path = line.substr(7); // Remove "file://"
            fl_value_append_take(paths_list, fl_value_new_string(path.c_str()));
          }
        }

        if (fl_value_get_length(paths_list) > 0) {
          fl_value_set_string_take(result_map, "files", fl_value_ref(paths_list));
        }

        g_free(uris_text);
      }
      gtk_selection_data_free(selection_data);
    }
  }

  // 图片格式
  if (gtk_clipboard_wait_is_image_available(clipboard)) {
    GdkPixbuf* pixbuf = gtk_clipboard_wait_for_image(clipboard);
    if (pixbuf != nullptr) {
      // 将 GdkPixbuf 转换为 PNG 字节数组
      gchar* buffer;
      gsize buffer_size;
      GError* error = nullptr;

      if (gdk_pixbuf_save_to_buffer(pixbuf, &buffer, &buffer_size, "png", &error, nullptr)) {
        g_autoptr(FlValue) image_list = fl_value_new_uint8_list(
            reinterpret_cast<const uint8_t*>(buffer), buffer_size);
        fl_value_set_string_take(result_map, "image", fl_value_ref(image_list));
        g_free(buffer);
      }

      g_object_unref(pixbuf);
    }
  }

  // 文本格式
  if (gtk_clipboard_wait_is_text_available(clipboard)) {
    gchar* text = gtk_clipboard_wait_for_text(clipboard);
    if (text != nullptr) {
      fl_value_set_string_take(result_map, "text", fl_value_new_string(text));
      g_free(text);
    }
  }

  fl_method_call_respond_success(method_call, result_map, nullptr);
}

static void clipboard_plugin_handle_method_call(
    ClipboardPlugin* self,
    FlMethodCall* method_call) {

  const gchar* method = fl_method_call_get_name(method_call);

  if (strcmp(method, "getClipboardFormats") == 0) {
    get_clipboard_formats(method_call);
  } else if (strcmp(method, "getClipboardType") == 0) {
    get_clipboard_type(method_call);
  } else if (strcmp(method, "getClipboardSequence") == 0) {
    get_clipboard_sequence(self, method_call);
  } else if (strcmp(method, "getClipboardFilePaths") == 0) {
    get_clipboard_file_paths(method_call);
  } else if (strcmp(method, "getClipboardImageData") == 0) {
    get_clipboard_image_data(method_call);
  } else if (strcmp(method, "performOCR") == 0) {
    perform_ocr(method_call);
  } else {
    fl_method_call_respond_not_implemented(method_call, nullptr);
  }
}

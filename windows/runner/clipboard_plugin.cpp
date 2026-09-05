#include "clipboard_plugin.h"

#include <flutter/standard_method_codec.h>

#include <string>
#include <vector>

namespace {

std::string WideToUtf8(const wchar_t* w) {
  if (!w) return {};
  int len = WideCharToMultiByte(CP_UTF8, 0, w, -1, nullptr, 0, nullptr, nullptr);
  if (len <= 1) return {};
  std::string out(static_cast<size_t>(len - 1), '\0');
  WideCharToMultiByte(CP_UTF8, 0, w, -1, out.data(), len, nullptr, nullptr);
  return out;
}

std::wstring Utf8ToWide(const std::string& s) {
  if (s.empty()) return {};
  int len = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
  std::wstring out(static_cast<size_t>(len), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), out.data(), len);
  return out;
}

// Copies a blob into a movable HGLOBAL suitable for SetClipboardData.
HGLOBAL BlobToGlobal(const void* data, size_t size) {
  HGLOBAL h = GlobalAlloc(GMEM_MOVEABLE, size);
  if (!h) return nullptr;
  void* p = GlobalLock(h);
  if (!p) {
    GlobalFree(h);
    return nullptr;
  }
  memcpy(p, data, size);
  GlobalUnlock(h);
  return h;
}

// Reads the whole content of a clipboard HGLOBAL.
bool GlobalToVector(HANDLE h, std::vector<uint8_t>* out) {
  if (!h) return false;
  SIZE_T size = GlobalSize(h);
  void* p = GlobalLock(h);
  if (!p) return false;
  out->assign(static_cast<uint8_t*>(p), static_cast<uint8_t*>(p) + size);
  GlobalUnlock(h);
  return true;
}

#pragma pack(push, 1)
struct BmpFileHeader {
  uint16_t type = 0x4D42;  // 'BM'
  uint32_t size = 0;
  uint16_t reserved1 = 0;
  uint16_t reserved2 = 0;
  uint32_t off_bits = 0;
};
#pragma pack(pop)

// Wraps a CF_DIB payload (BITMAPINFOHEADER + masks/palette + pixels) in a BMP
// file header so Dart's `image` package can decode it.
std::vector<uint8_t> DibToBmp(const std::vector<uint8_t>& dib) {
  if (dib.size() < sizeof(BITMAPINFOHEADER)) return {};
  const auto* bih = reinterpret_cast<const BITMAPINFOHEADER*>(dib.data());
  uint32_t header_size = bih->biSize;
  uint32_t colors = bih->biClrUsed;
  if (colors == 0 && bih->biBitCount <= 8) colors = 1u << bih->biBitCount;
  uint32_t masks = 0;
  if (bih->biCompression == BI_BITFIELDS && header_size == sizeof(BITMAPINFOHEADER)) {
    masks = 12;
  }
  BmpFileHeader fh;
  fh.off_bits = sizeof(BmpFileHeader) + header_size + masks + colors * 4;
  fh.size = static_cast<uint32_t>(sizeof(BmpFileHeader) + dib.size());
  std::vector<uint8_t> out(sizeof(BmpFileHeader) + dib.size());
  memcpy(out.data(), &fh, sizeof(fh));
  memcpy(out.data() + sizeof(fh), dib.data(), dib.size());
  return out;
}

}  // namespace

ClipboardPlugin::ClipboardPlugin(flutter::BinaryMessenger* messenger, HWND owner)
    : owner_(owner), png_format_(RegisterClipboardFormatW(L"PNG")) {
  method_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "clipsync/clipboard", &flutter::StandardMethodCodec::GetInstance());
  method_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) { HandleMethodCall(call, std::move(result)); });

  event_channel_ = std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
      messenger, "clipsync/clipboard_events", &flutter::StandardMethodCodec::GetInstance());
  event_channel_->SetStreamHandler(
      std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
          [this](const flutter::EncodableValue*,
                 std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events)
              -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
            sink_ = std::move(events);
            return nullptr;
          },
          [this](const flutter::EncodableValue*)
              -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
            sink_.reset();
            return nullptr;
          }));

  AddClipboardFormatListener(owner_);
}

ClipboardPlugin::~ClipboardPlugin() {
  if (owner_) RemoveClipboardFormatListener(owner_);
}

void ClipboardPlugin::OnClipboardUpdate() {
  DWORD seq = GetClipboardSequenceNumber();
  if (seq == last_own_sequence_) return;  // our own write
  if (sink_) sink_->Success(flutter::EncodableValue(static_cast<int64_t>(seq)));
}

bool ClipboardPlugin::OpenClipboardRetry() {
  // Another process may hold the clipboard for a few ms right after a copy.
  for (int i = 0; i < 10; i++) {
    if (OpenClipboard(owner_)) return true;
    Sleep(10);
  }
  return false;
}

void ClipboardPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  if (method == "changeCount") {
    result->Success(flutter::EncodableValue(static_cast<int64_t>(GetClipboardSequenceNumber())));
  } else if (method == "read") {
    result->Success(Read());
  } else if (method == "writeText") {
    const auto* text = std::get_if<std::string>(call.arguments());
    if (!text) {
      result->Error("args", "expected String");
      return;
    }
    WriteText(*text) ? result->Success() : result->Error("clipboard", "write failed");
  } else if (method == "writeImage") {
    const auto* map = std::get_if<flutter::EncodableMap>(call.arguments());
    if (!map) {
      result->Error("args", "expected map");
      return;
    }
    const std::vector<uint8_t>* png = nullptr;
    const std::vector<uint8_t>* bmp = nullptr;
    auto it = map->find(flutter::EncodableValue("png"));
    if (it != map->end()) png = std::get_if<std::vector<uint8_t>>(&it->second);
    it = map->find(flutter::EncodableValue("bmp"));
    if (it != map->end()) bmp = std::get_if<std::vector<uint8_t>>(&it->second);
    WriteImage(png, bmp) ? result->Success() : result->Error("clipboard", "write failed");
  } else {
    result->NotImplemented();
  }
}

flutter::EncodableValue ClipboardPlugin::Read() {
  flutter::EncodableMap out;
  if (!OpenClipboardRetry()) {
    out[flutter::EncodableValue("type")] = flutter::EncodableValue("none");
    return flutter::EncodableValue(out);
  }

  if (IsClipboardFormatAvailable(CF_UNICODETEXT)) {
    HANDLE h = GetClipboardData(CF_UNICODETEXT);
    if (h) {
      const wchar_t* w = static_cast<const wchar_t*>(GlobalLock(h));
      std::string text = WideToUtf8(w);
      GlobalUnlock(h);
      if (!text.empty()) {
        CloseClipboard();
        out[flutter::EncodableValue("type")] = flutter::EncodableValue("text");
        out[flutter::EncodableValue("text")] = flutter::EncodableValue(text);
        return flutter::EncodableValue(out);
      }
    }
  }

  std::vector<uint8_t> bytes;
  if (png_format_ && IsClipboardFormatAvailable(png_format_) &&
      GlobalToVector(GetClipboardData(png_format_), &bytes) && !bytes.empty()) {
    CloseClipboard();
    out[flutter::EncodableValue("type")] = flutter::EncodableValue("image");
    out[flutter::EncodableValue("png")] = flutter::EncodableValue(bytes);
    return flutter::EncodableValue(out);
  }

  // CF_DIB is synthesized by Windows from CF_BITMAP / CF_DIBV5 when needed.
  if (IsClipboardFormatAvailable(CF_DIB) &&
      GlobalToVector(GetClipboardData(CF_DIB), &bytes) && !bytes.empty()) {
    CloseClipboard();
    std::vector<uint8_t> bmp = DibToBmp(bytes);
    if (!bmp.empty()) {
      out[flutter::EncodableValue("type")] = flutter::EncodableValue("image");
      out[flutter::EncodableValue("bmp")] = flutter::EncodableValue(bmp);
      return flutter::EncodableValue(out);
    }
  }

  CloseClipboard();
  out[flutter::EncodableValue("type")] = flutter::EncodableValue("none");
  return flutter::EncodableValue(out);
}

bool ClipboardPlugin::WriteText(const std::string& utf8) {
  std::wstring w = Utf8ToWide(utf8);
  if (!OpenClipboardRetry()) return false;
  EmptyClipboard();
  HGLOBAL h = BlobToGlobal(w.c_str(), (w.size() + 1) * sizeof(wchar_t));
  bool ok = h && SetClipboardData(CF_UNICODETEXT, h) != nullptr;
  if (!ok && h) GlobalFree(h);
  CloseClipboard();
  last_own_sequence_ = GetClipboardSequenceNumber();
  return ok;
}

bool ClipboardPlugin::WriteImage(const std::vector<uint8_t>* png,
                                 const std::vector<uint8_t>* bmp) {
  if (!png && !bmp) return false;
  if (!OpenClipboardRetry()) return false;
  EmptyClipboard();
  bool ok = false;
  if (png && png_format_) {
    HGLOBAL h = BlobToGlobal(png->data(), png->size());
    if (h && SetClipboardData(png_format_, h)) {
      ok = true;
    } else if (h) {
      GlobalFree(h);
    }
  }
  if (bmp && bmp->size() > sizeof(BmpFileHeader) + sizeof(BITMAPINFOHEADER)) {
    // Strip the 14-byte file header; what remains is a DIB.
    const uint8_t* dib = bmp->data() + sizeof(BmpFileHeader);
    size_t dib_size = bmp->size() - sizeof(BmpFileHeader);
    uint32_t header_size = *reinterpret_cast<const uint32_t*>(dib);
    UINT format = header_size >= sizeof(BITMAPV5HEADER) ? CF_DIBV5 : CF_DIB;
    HGLOBAL h = BlobToGlobal(dib, dib_size);
    if (h && SetClipboardData(format, h)) {
      ok = true;
    } else if (h) {
      GlobalFree(h);
    }
  }
  CloseClipboard();
  last_own_sequence_ = GetClipboardSequenceNumber();
  return ok;
}

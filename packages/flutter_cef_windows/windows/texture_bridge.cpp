#include "texture_bridge.h"

#include <windows.h>

#include <cstdio>

namespace flutter_cef {

namespace {

void BridgeLog(const char* msg, long code = 0) {
  char buf[256];
  if (code) {
    _snprintf_s(buf, _TRUNCATE,
                "[flutter_cef_windows] TextureBridge: %s (hr=0x%08lx)\n", msg,
                code);
  } else {
    _snprintf_s(buf, _TRUNCATE, "[flutter_cef_windows] TextureBridge: %s\n",
                msg);
  }
  OutputDebugStringA(buf);
}

}  // namespace

// One session's texture state. The descriptor callback (engine raster thread)
// and Present (platform thread) both touch handle/dims/keepalive — guarded by
// `mutex`. The lambda captures a RAW Entry*; lifetime is guaranteed because
// the entry is kept alive by entries_ until Unregister, and from then on by
// the shared_ptr captured in the async-unregister completion callback, which
// the engine runs (or destroys) only after the texture can no longer be
// sampled.
struct TextureBridge::Entry {
  std::mutex mutex;
  FlutterDesktopGpuSurfaceDescriptor desc = {};
  uint64_t handle = 0;  // host-minted legacy shared handle — the identity
  uint32_t width = 0;
  uint32_t height = 0;
  // LAW 6 / S1 belt-1: opened D3D11 reference on the CURRENT bridge handle,
  // held for as long as it is fed to Flutter.
  Microsoft::WRL::ComPtr<ID3D11Texture2D> keepalive;
  std::unique_ptr<flutter::TextureVariant> variant;
};

TextureBridge::TextureBridge(flutter::TextureRegistrar* registrar)
    : registrar_(registrar) {}

TextureBridge::~TextureBridge() = default;

bool TextureBridge::EnsureDevice() {
  if (device_) return true;
  // Any D3D11 device can open + hold a legacy MISC_SHARED handle; the engine
  // opens the handle on ITS device via the descriptor. Ours only pins the
  // resource alive (LAW 6). Default adapter matches the spike-proven setup.
  UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
  HRESULT hr = D3D11CreateDevice(
      nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags, nullptr, 0,
      D3D11_SDK_VERSION, device_.GetAddressOf(), nullptr, nullptr);
  if (FAILED(hr)) {
    hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr, flags,
                           nullptr, 0, D3D11_SDK_VERSION,
                           device_.GetAddressOf(), nullptr, nullptr);
  }
  if (FAILED(hr)) {
    BridgeLog("D3D11CreateDevice failed", hr);
    return false;
  }
  return true;
}

int64_t TextureBridge::RegisterSessionTexture() {
  if (!registrar_) return -1;
  auto entry = std::make_shared<Entry>();
  Entry* raw = entry.get();
  entry->variant = std::make_unique<flutter::TextureVariant>(
      flutter::GpuSurfaceTexture(
          kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle,
          [raw](size_t /*width*/, size_t /*height*/)
              -> const FlutterDesktopGpuSurfaceDescriptor* {
            std::lock_guard<std::mutex> lock(raw->mutex);
            if (raw->handle == 0) {
              // Never painted: the engine skips this frame (checked-null
              // path in PopulateTexture) — no crash, tile stays blank.
              return nullptr;
            }
            raw->desc.struct_size =
                sizeof(FlutterDesktopGpuSurfaceDescriptor);
            raw->desc.handle = reinterpret_cast<void*>(
                static_cast<uintptr_t>(raw->handle));
            raw->desc.width = raw->width;
            raw->desc.height = raw->height;
            raw->desc.visible_width = raw->width;
            raw->desc.visible_height = raw->height;
            raw->desc.format = kFlutterDesktopPixelFormatNone;  // LAW 5
            raw->desc.release_context = nullptr;
            raw->desc.release_callback = [](void*) {};
            return &raw->desc;
          }));
  const int64_t id = registrar_->RegisterTexture(entry->variant.get());
  if (id < 0) {
    BridgeLog("RegisterTexture failed");
    return -1;
  }
  std::lock_guard<std::mutex> lock(entries_mutex_);
  entries_[id] = std::move(entry);
  return id;
}

bool TextureBridge::Present(int64_t texture_id, uint64_t bridge_handle,
                            uint32_t width, uint32_t height,
                            bool* handle_changed) {
  if (handle_changed) *handle_changed = false;
  if (bridge_handle == 0) return false;
  std::shared_ptr<Entry> entry;
  {
    std::lock_guard<std::mutex> lock(entries_mutex_);
    auto it = entries_.find(texture_id);
    if (it == entries_.end()) return false;
    entry = it->second;
  }

  bool changed;
  {
    std::lock_guard<std::mutex> lock(entry->mutex);
    changed = (entry->handle != bridge_handle);
  }

  // `previous` keeps the old opened ref alive until AFTER the swap (LAW 6:
  // release the previous only once the new one is being served).
  Microsoft::WRL::ComPtr<ID3D11Texture2D> previous;
  if (changed) {
    if (!EnsureDevice()) return false;
    Microsoft::WRL::ComPtr<ID3D11Texture2D> opened;
    HRESULT hr = device_->OpenSharedResource(
        reinterpret_cast<HANDLE>(static_cast<uintptr_t>(bridge_handle)),
        IID_PPV_ARGS(opened.GetAddressOf()));
    if (FAILED(hr)) {
      // #9: on device loss (removed/reset) the cached device is dead and every
      // OpenSharedResource on it keeps failing — drop it (+ this slot's opened
      // keepalive) so the next present re-creates the device via EnsureDevice
      // and reopens the host-re-minted handle fresh. A plain bad-handle miss
      // (host re-minted/freed racing us) just keeps the previous frame serving.
      if (FAILED(device_->GetDeviceRemovedReason())) {
        BridgeLog("device lost on OpenSharedResource — resetting device", hr);
        device_.Reset();
        std::lock_guard<std::mutex> lock(entry->mutex);
        entry->keepalive.Reset();
      } else {
        BridgeLog("OpenSharedResource failed — keeping previous frame", hr);
      }
      return false;
    }
    std::lock_guard<std::mutex> lock(entry->mutex);
    previous = std::move(entry->keepalive);
    entry->keepalive = std::move(opened);
    entry->handle = bridge_handle;
    entry->width = width;
    entry->height = height;
  } else {
    std::lock_guard<std::mutex> lock(entry->mutex);
    entry->width = width;
    entry->height = height;
  }

  registrar_->MarkTextureFrameAvailable(texture_id);
  if (handle_changed) *handle_changed = changed;
  return true;
  // `previous` released here — after the swap.
}

bool TextureBridge::GetCurrent(int64_t texture_id, uint64_t* handle,
                               uint32_t* width, uint32_t* height) {
  std::shared_ptr<Entry> entry;
  {
    std::lock_guard<std::mutex> lock(entries_mutex_);
    auto it = entries_.find(texture_id);
    if (it == entries_.end()) return false;
    entry = it->second;
  }
  std::lock_guard<std::mutex> lock(entry->mutex);
  if (handle) *handle = entry->handle;
  if (width) *width = entry->width;
  if (height) *height = entry->height;
  return true;
}

void TextureBridge::Unregister(int64_t texture_id) {
  std::shared_ptr<Entry> entry;
  {
    std::lock_guard<std::mutex> lock(entries_mutex_);
    auto it = entries_.find(texture_id);
    if (it == entries_.end()) return;
    entry = std::move(it->second);
    entries_.erase(it);
  }
  // Async unregister (PLAN §2 #7): the engine may still sample the texture /
  // call the descriptor callback until the completion callback fires. The
  // captured shared_ptr keeps the entry (variant + descriptor + keep-alive
  // ComPtr) alive exactly until the engine runs or destroys the callback —
  // no bridge state is touched in it, so plugin teardown ordering is safe.
  registrar_->UnregisterTexture(texture_id, [entry]() {});
}

}  // namespace flutter_cef

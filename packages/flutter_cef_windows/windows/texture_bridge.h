// TextureBridge — owns the Flutter GPU texture a session presents into.
//
// The real bridge, per PROTOCOL.md §5 and the LAWS:
//  - Each session gets a flutter::GpuSurfaceTexture
//    (kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle) whose descriptor callback
//    serves the CURRENT host-minted bridge handle under a mutex
//    (validated by the P0 S1 spike — see specs/windows-port/SPIKES.md).
//  - Descriptor: struct_size SET, width/height AND visible_width/height,
//    format = kFlutterDesktopPixelFormatNone (LAW 5). Returns nullptr before
//    the first present — the engine skips the frame (PopulateTexture checks
//    descriptor/handle for null and bails).
//  - Present() holds an opened ID3D11Texture2D ComPtr on the CURRENT bridge
//    handle for as long as it is fed to Flutter, releasing the previous one
//    only AFTER the swap (LAW 6, S1 belt-1).
//  - Identity is the host-minted bridge handle value we are handed — never
//    CEF's per-callback shared_texture_handle (LAW 3). The size-gate (LAW 4)
//    is the CALLER's job (the plugin compares srcW/srcH against the expected
//    round(logical*dpr) before calling Present).
//  - UnregisterTexture is ASYNC on Windows: the entry (variant + descriptor +
//    keep-alive ComPtr) is captured by the completion callback and freed when
//    the engine releases it (PLAN §2 #7) — no graveyard, no leak-to-teardown.

#ifndef FLUTTER_PLUGIN_FLUTTER_CEF_TEXTURE_BRIDGE_H_
#define FLUTTER_PLUGIN_FLUTTER_CEF_TEXTURE_BRIDGE_H_

#include <d3d11.h>
#include <flutter/texture_registrar.h>
#include <wrl/client.h>

#include <cstdint>
#include <map>
#include <memory>
#include <mutex>

namespace flutter_cef {

class TextureBridge {
 public:
  explicit TextureBridge(flutter::TextureRegistrar* registrar);
  ~TextureBridge();

  TextureBridge(const TextureBridge&) = delete;
  TextureBridge& operator=(const TextureBridge&) = delete;

  // Registers a GpuSurfaceTexture for a new session (no backing handle yet —
  // the descriptor callback returns nullptr until the first Present).
  // Returns the Flutter texture id, or -1 on failure. Platform thread only.
  int64_t RegisterSessionTexture();

  // Promotes `bridge_handle` (the host-minted DXGI LEGACY shared handle) as
  // the texture's backing surface and marks a frame available.
  // width/height are the frame's physical px (already size-gated by the
  // caller). On a handle change, opens the handle on our D3D11 device and
  // holds the ComPtr (LAW 6), releasing the previous ref AFTER the swap.
  // Returns false if the entry is unknown or the handle could not be opened
  // (previous texture keeps serving). *handle_changed reports whether the
  // backing surface identity changed (drives the onSurface event).
  bool Present(int64_t texture_id, uint64_t bridge_handle, uint32_t width,
               uint32_t height, bool* handle_changed);

  // Current backing info for getFrameSurface: false if unknown/no frame yet.
  bool GetCurrent(int64_t texture_id, uint64_t* handle, uint32_t* width,
                  uint32_t* height);

  // Asynchronously unregisters `texture_id`; the backing entry stays alive
  // until the engine's completion callback runs. Platform thread only.
  void Unregister(int64_t texture_id);

 private:
  struct Entry;

  bool EnsureDevice();

  flutter::TextureRegistrar* registrar_;  // owned by the engine
  Microsoft::WRL::ComPtr<ID3D11Device> device_;
  std::mutex entries_mutex_;
  std::map<int64_t, std::shared_ptr<Entry>> entries_;
};

}  // namespace flutter_cef

#endif  // FLUTTER_PLUGIN_FLUTTER_CEF_TEXTURE_BRIDGE_H_

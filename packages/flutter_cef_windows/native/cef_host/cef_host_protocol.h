// flutter_cef Windows — wire framing constants + big-endian codecs.
//
// Shared by the cef_host process (native/cef_host/cef_host_win.cc) and the
// Flutter plugin (windows/ipc_pipe.cpp): plain C++/Win32, no CEF includes, so
// both builds can consume it. The opcodes and the protocol version are in
// cef_host_opcodes.h, generated from tool/protocol/spec.dart. Framing:
//   [u32 bodyLen BE][u32 browserId BE][u8 opcode][payload]
// bodyLen = 4 + 1 + payloadLen; guard 5 <= bodyLen <= 64 MiB; browserId 0 =
// process-level (kOpReady, process-level kOpLog, inbound kOpShutdown).

#ifndef FLUTTER_CEF_WINDOWS_NATIVE_CEF_HOST_CEF_HOST_PROTOCOL_H_
#define FLUTTER_CEF_WINDOWS_NATIVE_CEF_HOST_CEF_HOST_PROTOCOL_H_

#include <cstdint>
#include <cstring>

#include "cef_host_opcodes.h"

namespace flutter_cef {

// Framing guard, as on macOS: minimum body = 4 (browserId) + 1 (op).
constexpr uint32_t kMinBodyLen = 5;
constexpr uint32_t kMaxBodyLen = 64u << 20;  // 64 MiB

// ---- Big-endian codecs (mirror the macOS host's ipc.h) ----

inline uint32_t ReadU32BE(const uint8_t* p) {
  return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) |
         (uint32_t(p[2]) << 8) | uint32_t(p[3]);
}

inline void WriteU32BE(uint8_t* p, uint32_t v) {
  p[0] = static_cast<uint8_t>((v >> 24) & 0xff);
  p[1] = static_cast<uint8_t>((v >> 16) & 0xff);
  p[2] = static_cast<uint8_t>((v >> 8) & 0xff);
  p[3] = static_cast<uint8_t>(v & 0xff);
}

inline uint64_t ReadU64BE(const uint8_t* p) {
  return (uint64_t(ReadU32BE(p)) << 32) | uint64_t(ReadU32BE(p + 4));
}

inline void WriteU64BE(uint8_t* p, uint64_t v) {
  WriteU32BE(p, static_cast<uint32_t>(v >> 32));
  WriteU32BE(p + 4, static_cast<uint32_t>(v & 0xffffffffu));
}

inline double ReadF64BE(const uint8_t* p) {
  uint64_t bits = ReadU64BE(p);
  double d;
  static_assert(sizeof(d) == sizeof(bits), "double must be 64-bit");
  std::memcpy(&d, &bits, sizeof(d));
  return d;
}

inline void WriteF64BE(uint8_t* p, double d) {
  uint64_t bits;
  std::memcpy(&bits, &d, sizeof(bits));
  WriteU64BE(p, bits);
}

}  // namespace flutter_cef

#endif  // FLUTTER_CEF_WINDOWS_NATIVE_CEF_HOST_CEF_HOST_PROTOCOL_H_

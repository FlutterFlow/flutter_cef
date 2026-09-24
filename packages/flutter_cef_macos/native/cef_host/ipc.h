// The IPC socket to the plugin: frame writing (any thread), frame reading
// helpers for the reader thread, and the size limits that keep one page from
// costing every browser on the host its connection.
//
// Frame layout: [u32 bodyLen BE][u32 browserId BE][u8 opcode][payload]. browserId
// is the Swift-assigned wire id of the originating browser; 0 for process-level
// frames (kOpReady, process-level kOpLog). bodyLen = 4 (browserId) + 1 (op) +
// payloadLen, counting every byte after the length prefix.
#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <mutex>
#include <string>

#include "cef_host_opcodes.h"  // generated from tool/protocol/spec.dart

namespace cef_host {

// Atomic: the reader thread reads it (ReadAll), SendFrame on any thread reads it,
// and main() stores the connected fd then -1 on teardown. A plain int would tear
// the SendFrame `< 0` check against the teardown `= -1` store (UB, and benign
// only because a closed-fd write is a safe no-op); the atomic makes it defined.
extern std::atomic<int> g_ipc_fd;
// Serializes frame writes, and the teardown that closes g_ipc_fd.
extern std::mutex g_ipc_write_mutex;

// The plugin's reader drops the connection on a frame body over this size, which
// ends every browser on the host, so nothing larger is ever sent.
constexpr uint32_t kMaxFrameBody = 64u << 20;
// What a page may put in one message (an eval result, a channel post) or one
// text field that goes out whole. Well under kMaxFrameBody.
constexpr size_t kMaxPageMessage = 16u << 20;
constexpr size_t kMaxPageText = 1u << 20;

bool ReadAll(int fd, void* buf, size_t len);

void SendFrame(uint32_t browser_id, uint8_t opcode, const void* payload,
               size_t payload_len);
void SendLog(uint32_t browser_id, const std::string& msg);
void SendUtf8(uint32_t browser_id, uint8_t op, const std::string& s);
void SendLoadState(uint32_t browser_id, bool loading, bool back, bool forward);
// op payload: [u32 BE code][utf8 body]. Used for load-error and console.
void SendCodePlusUtf8(uint32_t browser_id, uint8_t op, uint32_t code,
                      const std::string& body);

uint32_t ReadU32BE(const uint8_t* p);
void WriteU32BE(uint8_t* p, uint32_t v);
double ReadF64BE(const uint8_t* p);

// `s` cut to at most `max` bytes, on a UTF-8 character boundary, with a marker
// when anything was cut.
std::string TruncateUtf8(const std::string& s, size_t max);
// 128 random bits as hex.
std::string RandomNonce();
// JSON-escape a UTF-8 string (without the surrounding quotes).
std::string JsonEscape(const std::string& s);

}  // namespace cef_host

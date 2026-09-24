// A security descriptor whose DACL is PROTECTED and grants GENERIC_ALL to the
// current user's SID only. Shared by the IPC pipe (ipc_pipe.cpp) and the
// persistent profile tree (flutter_cef_plugin.cpp).
//
// PROTECTED (SDDL "P") blocks inherited ACEs, so nothing a squatter controls
// can widen access. `inheritable` adds OICI (object + container inherit): a
// directory tree needs it so the files and subdirs Chromium creates under the
// profile (Default/Network/Cookies, Local State, ...) inherit the user's
// access. Without it the owner lacks FILE_READ_DATA on them, and a freshly
// spawned cef_host can't read the cookie store it wrote last run ("stay signed
// in" silently fails). A single kernel object like the pipe omits it.

#ifndef FLUTTER_PLUGIN_FLUTTER_CEF_CURRENT_USER_SD_H_
#define FLUTTER_PLUGIN_FLUTTER_CEF_CURRENT_USER_SD_H_

#include <windows.h>
#include <sddl.h>

#include <cstdint>
#include <string>
#include <vector>

#pragma comment(lib, "advapi32.lib")

namespace flutter_cef {

// On success *out_sd is a LocalAlloc'd descriptor the caller must LocalFree
// after the API call that consumed it.
inline bool BuildCurrentUserOnlySD(PSECURITY_DESCRIPTOR* out_sd,
                                   bool inheritable) {
  *out_sd = nullptr;
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return false;
  DWORD len = 0;
  GetTokenInformation(token, TokenUser, nullptr, 0, &len);  // size probe
  if (len == 0) {
    CloseHandle(token);
    return false;
  }
  std::vector<uint8_t> buf(len);
  const bool got =
      GetTokenInformation(token, TokenUser, buf.data(), len, &len) != FALSE;
  CloseHandle(token);
  if (!got) return false;
  auto* tu = reinterpret_cast<TOKEN_USER*>(buf.data());
  LPWSTR sid_str = nullptr;
  if (!ConvertSidToStringSidW(tu->User.Sid, &sid_str)) return false;
  // D:P = a protected DACL; (A;<flags>;GA;;;<SID>) = allow GENERIC_ALL to the
  // current user's SID only.
  const std::wstring sddl = std::wstring(L"D:P(A;") +
                            (inheritable ? L"OICI" : L"") + L";GA;;;" +
                            sid_str + L")";
  LocalFree(sid_str);
  return ConvertStringSecurityDescriptorToSecurityDescriptorW(
             sddl.c_str(), SDDL_REVISION_1, out_sd, nullptr) != FALSE;
}

}  // namespace flutter_cef

#endif  // FLUTTER_PLUGIN_FLUTTER_CEF_CURRENT_USER_SD_H_

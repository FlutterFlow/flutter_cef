// macOS text key bindings for the off-screen browser.
//
// In a windowed Chrome, AppKit's key-binding manager turns a keystroke into edit
// selectors (⌘← -> moveToLeftEndOfLine:, ⌃K -> deleteToEndOfParagraph:, …) and
// Chromium attaches them to the keydown as "edit commands". Blink runs them as
// the key's DEFAULT action, so a page that handles the key itself (Monaco, a
// Flutter web app) still wins. An OSR browser has no NSView in the responder
// chain, so nothing produces those selectors and every binding AppKit owns —
// all the ⌘/⌃ ones — is dead in plain <input>/<textarea>/contenteditable.
//
// This reads the SAME source AppKit does — the system StandardKeyBinding.dict,
// then the user's ~/Library/KeyBindings/DefaultKeyBinding.dict — so there is no
// hand-kept shortcut list to drift. The host delivers a matching keydown through
// DevTools `Input.dispatchKeyEvent`, whose `commands` field is that same
// edit-command channel.
#pragma once

#import <Foundation/Foundation.h>

#include <cstdint>
#include <map>
#include <string>
#include <vector>

#include "include/internal/cef_types.h"

namespace mac_key_bindings {

struct Match {
  std::string code;  // DOM KeyboardEvent.code
  std::string key;   // DOM KeyboardEvent.key
  std::vector<std::string> commands;
};

namespace internal {

enum : uint32_t { kShift = 1, kControl = 2, kOption = 4, kCommand = 8 };

// The navigation/deletion keys, as AppKit names them in a binding (NSEvent
// function-key codepoints) and as the DOM does (code == key for all of these).
struct NamedKey {
  int vk;
  char16_t ns_char;
  const char* dom_name;
};
constexpr NamedKey kNamedKeys[] = {
    {0x08, 0x007F, "Backspace"}, {0x21, 0xF72C, "PageUp"},
    {0x22, 0xF72D, "PageDown"},  {0x23, 0xF72B, "End"},
    {0x24, 0xF729, "Home"},      {0x25, 0xF702, "ArrowLeft"},
    {0x26, 0xF700, "ArrowUp"},   {0x27, 0xF703, "ArrowRight"},
    {0x28, 0xF701, "ArrowDown"}, {0x2E, 0xF728, "Delete"},
};

inline uint32_t BindingKey(uint32_t mods, char16_t ch) {
  return (mods << 16) | ch;
}

// One binding-dict key: modifier flags (^ control, ~ option, $ shift, @ command)
// followed by the key's character. An uppercase letter means shift.
inline bool ParseBinding(NSString* spec, uint32_t* mods, char16_t* ch) {
  const NSUInteger n = spec.length;
  if (n == 0) return false;
  *mods = 0;
  for (NSUInteger i = 0; i + 1 < n; i++) {
    switch ([spec characterAtIndex:i]) {
      case '^': *mods |= kControl; break;
      case '~': *mods |= kOption; break;
      case '$': *mods |= kShift; break;
      case '@': *mods |= kCommand; break;
      default: return false;  // '#' (numpad) or a form we don't model
    }
  }
  unichar c = [spec characterAtIndex:n - 1];
  if (c >= 'A' && c <= 'Z') {
    *mods |= kShift;
    c = c - 'A' + 'a';
  }
  *ch = c;
  return true;
}

inline void LoadBindings(NSString* path,
                         std::map<uint32_t, std::vector<std::string>>* out) {
  NSDictionary* dict = [NSDictionary dictionaryWithContentsOfFile:path];
  if (![dict isKindOfClass:[NSDictionary class]]) return;
  for (NSString* spec in dict) {
    id value = dict[spec];
    NSArray* selectors = nil;
    if ([value isKindOfClass:[NSString class]]) {
      selectors = @[ value ];
    } else if ([value isKindOfClass:[NSArray class]]) {
      selectors = value;
    } else {
      continue;  // a nested dict is a multi-keystroke binding
    }
    uint32_t mods = 0;
    char16_t ch = 0;
    if (![spec isKindOfClass:[NSString class]] || !ParseBinding(spec, &mods, &ch))
      continue;
    std::vector<std::string> commands;
    bool usable = true;
    for (id sel in selectors) {
      if (![sel isKindOfClass:[NSString class]]) { usable = false; break; }
      NSString* name = sel;
      // Chromium drops text-inserting selectors from a keydown's edit commands
      // (the text arrives through the input method instead). A binding that
      // needs one can't be half-applied, so it stays on the ordinary key path.
      if ([name hasPrefix:@"insert"]) { usable = false; break; }
      if ([name isEqualToString:@"noop:"]) continue;
      if ([name hasSuffix:@":"]) name = [name substringToIndex:name.length - 1];
      commands.push_back(name.UTF8String);
    }
    // A user binding overrides the system one even when it disables the key.
    if (usable && !commands.empty()) {
      (*out)[BindingKey(mods, ch)] = std::move(commands);
    } else {
      out->erase(BindingKey(mods, ch));
    }
  }
}

inline const std::map<uint32_t, std::vector<std::string>>& Bindings() {
  static const auto* bindings = [] {
    auto* m = new std::map<uint32_t, std::vector<std::string>>();
    @autoreleasepool {
      NSBundle* appkit = [NSBundle bundleWithIdentifier:@"com.apple.AppKit"];
      NSString* standard = [appkit pathForResource:@"StandardKeyBinding"
                                            ofType:@"dict"];
      if (standard) LoadBindings(standard, m);
      LoadBindings([NSHomeDirectory()
                       stringByAppendingPathComponent:
                           @"Library/KeyBindings/DefaultKeyBinding.dict"],
                   m);
    }
    return m;
  }();
  return *bindings;
}

}  // namespace internal

// The edit commands AppKit binds to this keydown, if it is one only AppKit
// would have handled: a navigation/deletion key or a letter, held with ⌘, ⌃ or
// ⌥. Unmodified and shift-only keys are Blink's own and never match.
inline bool Lookup(uint32_t cef_modifiers, int vk, Match* out) {
  using namespace internal;
  uint32_t mods = 0;
  if (cef_modifiers & EVENTFLAG_SHIFT_DOWN) mods |= kShift;
  if (cef_modifiers & EVENTFLAG_CONTROL_DOWN) mods |= kControl;
  if (cef_modifiers & EVENTFLAG_ALT_DOWN) mods |= kOption;
  if (cef_modifiers & EVENTFLAG_COMMAND_DOWN) mods |= kCommand;
  if (!(mods & (kControl | kOption | kCommand))) return false;

  char16_t ch = 0;
  std::string code, key;
  if (vk >= 'A' && vk <= 'Z') {
    ch = static_cast<char16_t>(vk - 'A' + 'a');
    code = std::string("Key") + static_cast<char>(vk);
    key = std::string(1, static_cast<char>((mods & kShift) ? vk : ch));
  } else {
    for (const NamedKey& k : kNamedKeys) {
      if (k.vk != vk) continue;
      ch = k.ns_char;
      code = key = k.dom_name;
      break;
    }
  }
  if (!ch) return false;

  const auto& bindings = Bindings();
  auto it = bindings.find(BindingKey(mods, ch));
  if (it == bindings.end()) return false;
  out->code = std::move(code);
  out->key = std::move(key);
  out->commands = it->second;
  return true;
}

}  // namespace mac_key_bindings

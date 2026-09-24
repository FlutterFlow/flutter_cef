// The cef_host wire protocol: the one definition of every opcode.
//
// `dart run tool/protocol/generate.dart` writes the per-package copies from
// this file (each federated package builds standalone, so they can't include a
// shared header):
//   * macOS host   packages/flutter_cef_macos/native/cef_host/cef_host_opcodes.h
//   * macOS plugin packages/flutter_cef_macos/macos/Classes/CefHostOpcodes.swift
//   * Windows host + plugin
//                  packages/flutter_cef_windows/native/cef_host/cef_host_opcodes.h
//   * the opcode table in packages/flutter_cef_windows/native/cef_host/PROTOCOL.md
// test/protocol_parity_test.dart fails when a copy is stale or when an opcode
// is defined by hand anywhere else.
//
// Framing (both platforms): [u32 bodyLen BE][u32 browserId BE][u8 opcode]
// [payload], bodyLen = 5 + payload length. browserId 0 is process-level.
// Integers are big-endian.

enum Platform { macos, windows }

enum Direction {
  /// cef_host -> plugin: an event.
  toPlugin,

  /// plugin -> cef_host: a command.
  toHost,
}

class Op {
  const Op(
    this.code,
    this.name,
    this.direction,
    this.payload, {
    this.platforms = const {Platform.macos, Platform.windows},
    this.windowsPayload,
  });

  final int code;

  /// PascalCase; `kOp<name>` in C++, `CefOp.<lowerCamel>` in Swift.
  final String name;
  final Direction direction;
  final String payload;
  final Set<Platform> platforms;

  /// Where Windows' payload differs from macOS'.
  final String? windowsPayload;

  String payloadOn(Platform p) =>
      p == Platform.windows ? (windowsPayload ?? payload) : payload;
}

/// Bump a platform's version on any change its other side can't ignore; a
/// mismatch fails every session with processGone('protocolMismatch(host=vN)').
/// The host announces it in kOpReady's payload byte 1.
const protocolVersions = {
  // v10: kOpBrowserGone (one browser's renderer keeps crashing).
  Platform.macos: 10,
  // v6: kOpBrowserGone (one browser's renderer keeps crashing).
  Platform.windows: 6,
};

const _mac = {Platform.macos};
const _up = Direction.toPlugin;
const _down = Direction.toHost;

const ops = <Op>[
  // ---- cef_host -> plugin ----
  Op(0x01, 'Present', _up,
      '{u32 iosurfaceId}{u32 srcW}{u32 srcH}: a frame was presented. srcW/srcH are the physical pixel size of the composited frame.',
      windowsPayload:
          '{u64 bridgeHandle}{u32 srcW}{u32 srcH}: bridgeHandle is the DXGI legacy shared handle of the host-minted bridge texture.'),
  Op(0x02, 'Ready', _up,
      '{u8 readyFlags}{u8 protocolVersion} on browserId 0, before any browser exists. readyFlags bit0 = ad-hoc (mock keychain) build; Windows sends 0.'),
  Op(0x03, 'Cursor', _up, '{u32 cef_cursor_type_t}'),
  Op(0x04, 'Log', _up, '{utf8 message}; browserId 0 = process-level'),
  Op(0x05, 'LoadState', _up, '{u8 loading}{u8 canGoBack}{u8 canGoForward}'),
  Op(0x06, 'Title', _up, '{utf8 title}'),
  Op(0x07, 'Url', _up, '{utf8 main-frame url}'),
  Op(0x08, 'LoadErr', _up, '{u32 code}{utf8 "url\\ntext"}'),
  Op(0x09, 'Console', _up, '{u32 level}{utf8 "source:line\\tmsg"}'),
  Op(0x0a, 'PageStart', _up, '{utf8 url} main-frame load started'),
  Op(0x0b, 'PageFinish', _up, '{utf8 url} main-frame load finished'),
  Op(0x0c, 'Progress', _up, '{u32 percent 0-100}'),
  Op(0x0d, 'NewWindow', _up, '{utf8 url} popup / target=_blank'),
  Op(0x0e, 'FindResult', _up, '{u32 count}{u32 activeOrdinal}{u8 final}'),
  Op(0x0f, 'JsDialog', _up,
      '{u32 id}{u32 type}{u32 msgLen}{utf8 msg}{utf8 defaultText}'),
  Op(0x16, 'EvalResult', _up, '{utf8 "id:json"} reply to kOpEvalReturning'),
  Op(0x17, 'ChannelMsg', _up, '{utf8 "name:message"} JS channel -> plugin'),
  Op(0x18, 'Download', _up, '{utf8 suggestedName} a download started'),
  Op(0x19, 'ImeBounds', _up, '{u32 x}{u32 y}{u32 w}{u32 h} caret rect (DIP)'),
  Op(0x1a, 'Cookies', _up,
      '{u32 id}{utf8 json-array} reply to kOpVisitCookies'),
  Op(0x1b, 'TargetId', _up,
      '{utf8 targetId} this browser\'s CDP targetId, reply to kOpResolveTargetId'),
  Op(0x1c, 'Created', _up,
      '{} OnAfterCreated: the browser is up; the plugin paces the next create on it'),
  Op(0x1d, 'CreateFailed', _up,
      '{} the async CreateBrowser dispatch failed; the plugin drops the session'),
  Op(0x1e, 'MediaRequest', _up,
      '{u32 id}{u32 requested}{utf8 origin} getUserMedia with no remembered decision; answer with kOpMediaResponse',
      platforms: _mac),
  Op(0x1f, 'MediaState', _up,
      '{u8 videoActive}{u8 audioActive}{u8 setting 0=ask 1=allow} the page\'s camera/mic status',
      platforms: _mac),
  Op(0x40, 'ContextMenu', _up,
      '{u32 id}{utf8 json} right-click: Chromium\'s menu model and params, for the plugin\'s consumer to draw; answer with kOpContextMenuCommand',
      platforms: _mac),
  Op(0x42, 'BrowserGone', _up,
      '{utf8 reason} this one browser can\'t continue (its renderer keeps crashing); the process survives and the plugin drops the session'),

  // ---- plugin -> cef_host ----
  Op(0x10, 'Pointer', _down,
      '{u8 type}{u8 button}{u8 clickCount}{u8 pad}{u32 modifiers}{f64 x}{f64 y}{f64 dx}{f64 dy}; type 0=move 1=down 2=up 3=wheel 4=leave, button 0=left 1=middle 2=right, x/y in DIP'),
  Op(0x11, 'Resize', _down,
      '{u32 w}{u32 h}[{f64 dpr}]: dpr absent or 0 = unchanged, must be in (0, 8]'),
  Op(0x12, 'Key', _down,
      '{u8 type}{u8 pad x3}{u32 modifiers}{u32 windowsKeyCode}{u32 nativeKeyCode}{u32 character}; type 0=rawkeydown 2=keyup 3=char'),
  Op(0x13, 'CreateBrowser', _down,
      '{u32 w}{u32 h}{f64 dpr}{utf8 url}; the frame\'s browserId is the NEW id; empty url = about:blank'),
  Op(0x14, 'Shutdown', _down, '{} on browserId 0: end the whole process'),
  Op(0x15, 'DisposeBrowser', _down,
      '{} close one browser; the process survives'),
  Op(0x20, 'Navigate', _down, '{utf8 url}'),
  Op(0x21, 'Reload', _down, '{}'),
  Op(0x22, 'Stop', _down, '{}'),
  Op(0x23, 'Back', _down, '{}'),
  Op(0x24, 'Forward', _down, '{}'),
  Op(0x25, 'ExecuteJs', _down, '{utf8 code}'),
  Op(0x26, 'SetZoom', _down, '{f64 level}; factor = 1.2^level'),
  Op(0x27, 'Find', _down, '{u8 forward}{u8 matchCase}{u8 findNext}{utf8 text}'),
  Op(0x28, 'StopFind', _down, '{u8 clearSelection}; absent = 1'),
  Op(0x29, 'JsDialogResp', _down, '{u32 id}{u8 ok}{utf8 text}'),
  Op(0x2a, 'EvalReturning', _down,
      '{u32 id}{utf8 expression}; replies kOpEvalResult'),
  Op(0x2b, 'AddChannel', _down, '{utf8 name} register a JS channel'),
  Op(0x2c, 'SetCookie', _down,
      '{utf8 url\\0name\\0value\\0domain\\0path[\\0secure(0|1)\\0httpOnly(0|1)\\0sameSite(unspecified|none|lax|strict)]}'),
  Op(0x2d, 'ClearCookies', _down, '{} delete all cookies'),
  Op(0x2e, 'VisitCookies', _down,
      '{u32 id}{utf8 url}; empty url = all; replies kOpCookies'),
  Op(0x2f, 'DeleteCookie', _down, '{utf8 url\\0name}'),
  Op(0x30, 'ImeSetComp', _down, '{utf8 text} IME composition update'),
  Op(0x31, 'ImeCommit', _down, '{utf8 text} commit composed text'),
  Op(0x32, 'ImeCancel', _down, '{} cancel composition'),
  Op(0x33, 'ShowDevTools', _down,
      '{} or {u32 x}{u32 y}: open DevTools in a window, inspecting the element at the point if given',
      windowsPayload: '{} open DevTools in a window'),
  Op(0x34, 'LoadTrusted', _down,
      '{utf8 url} a load by the embedder, exempt from the scheme allowlist'),
  Op(0x35, 'SetVisible', _down, '{u8 visible}; absent = 1'),
  Op(0x36, 'ResolveTargetId', _down, '{} replies kOpTargetId'),
  Op(0x37, 'Invalidate', _down,
      '{} force a repaint, to re-kick a stalled first frame'),
  Op(0x38, 'EditCommand', _down,
      '{u8 cmd} in the focused frame: 0=copy 1=cut 2=paste 3=selectAll 4=undo 5=redo'),
  Op(0x39, 'OpenAuthWindow', _down,
      '{utf8 url} open a windowed browser, sharing the tile\'s cookies, for a WebAuthn ceremony the tile can\'t host',
      platforms: _mac),
  Op(0x3a, 'SetAudioMuted', _down, '{u8 muted}'),
  Op(0x3b, 'SetPumpInterval', _down,
      '{u16 ms} visible begin-frame cadence, clamped to [8, 250]'),
  Op(0x3c, 'MediaResponse', _down,
      '{u32 id}{u8 allow}{u8 remember} answer a kOpMediaRequest; remembered per origin only when remember is set',
      platforms: _mac),
  Op(0x3d, 'SetMediaSetting', _down,
      '{u8 0=ask 1=allow 2=block} rewrite the current origin\'s camera+mic setting; applies the next time the page asks',
      platforms: _mac),
  Op(0x3e, 'ContextMenuCommand', _down,
      '{u32 id}{u32 commandId} run the chosen kOpContextMenu command; 0 = dismissed',
      platforms: _mac),
  Op(0x3f, 'SetAuthoredHtml', _down,
      '{utf8 baseUrl}\\0{utf8 html}: store-only; serve html as the main-frame response for exactly baseUrl (empty html clears it). The load is a following kOpCreateBrowser or kOpLoadTrusted for that URL'),
  Op(0x41, 'SetDocumentStart', _down,
      '({u8 kind}{u32 len}{utf8})*, kind 0 = JS channel name, 1 = script (document_start.h): store-only, for the browser created right behind it'),
];

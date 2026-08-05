/// A failed navigation reported by the page.
class CefLoadError {
  const CefLoadError({
    required this.errorCode,
    required this.url,
    required this.errorText,
  });

  /// CEF `cef_errorcode_t` (e.g. -106 = ERR_INTERNET_DISCONNECTED, -105 =
  /// ERR_NAME_NOT_RESOLVED).
  final int errorCode;

  /// The URL that failed to load.
  final String url;

  /// A human-readable description of the failure.
  final String errorText;

  @override
  String toString() => 'CefLoadError($errorCode, $url: $errorText)';
}

/// A `console.*` message emitted by the page.
class CefConsoleMessage {
  const CefConsoleMessage({required this.level, required this.message});

  /// CEF `cef_log_severity_t`: 0 default, 1 verbose/debug, 2 info, 3 warning,
  /// 4 error, 5 fatal.
  final int level;

  /// `"source:line\tmessage"`.
  final String message;

  @override
  String toString() => 'CefConsoleMessage($level, $message)';
}

/// A find-in-page result update (see [CefWebController.find]).
class CefFindResult {
  const CefFindResult({
    required this.numberOfMatches,
    required this.activeMatchOrdinal,
    required this.isFinalUpdate,
  });

  /// Total matches for the current search.
  final int numberOfMatches;

  /// 1-based index of the currently highlighted match (0 if none).
  final int activeMatchOrdinal;

  /// True on the last update for a search (counts are stable).
  final bool isFinalUpdate;

  @override
  String toString() =>
      'CefFindResult($activeMatchOrdinal/$numberOfMatches, final: $isFinalUpdate)';
}

/// A JavaScript dialog (`alert` / `confirm` / `prompt`) the page raised. Passed
/// to the [CefWebController] dialog callbacks; reply by returning from them.
class CefJsDialogRequest {
  const CefJsDialogRequest({required this.message, this.defaultText = ''});

  /// The dialog message text.
  final String message;

  /// The pre-filled value for a `prompt()` dialog (empty otherwise).
  final String defaultText;

  @override
  String toString() => 'CefJsDialogRequest($message)';
}

/// A page's request to use the camera and/or microphone (`getUserMedia`),
/// raised only when the site has no remembered decision. Passed to
/// [CefWebController.onMediaPermissionRequest]; answer by returning
/// allow/deny, and the answer is remembered for [origin].
///
/// The grant is all-or-nothing: CEF requires the answer to a `getUserMedia`
/// request to cover exactly what was asked for, so a page wanting camera AND
/// mic cannot be granted just one.
class CefMediaPermissionRequest {
  const CefMediaPermissionRequest({
    required this.origin,
    required this.camera,
    required this.microphone,
  });

  /// The security origin that asked — the requesting frame's own origin, which
  /// for a cross-origin iframe is NOT the address-bar URL.
  final String origin;

  /// Whether camera access was requested.
  final bool camera;

  /// Whether microphone access was requested.
  final bool microphone;

  @override
  String toString() =>
      'CefMediaPermissionRequest($origin, camera: $camera, mic: $microphone)';
}

/// What a site is remembered as being allowed to do with camera/mic.
enum CefMediaSetting {
  /// No stored decision — the page will raise a permission request.
  ask,

  /// Remembered allow: `getUserMedia` succeeds without prompting.
  allow,

  /// Remembered block: `getUserMedia` is refused without prompting.
  block,
}

/// Live camera/microphone status for a page: whether capture is actually
/// happening right now, plus the site's remembered decision. Delivered by
/// [CefWebController.mediaState]; the capture flags are the honest source for
/// an "in use" indicator, since they reflect what Chromium is really capturing
/// rather than what was merely permitted.
class CefMediaState {
  const CefMediaState({
    this.videoActive = false,
    this.audioActive = false,
    this.setting = CefMediaSetting.ask,
  });

  /// The camera is capturing right now.
  final bool videoActive;

  /// The microphone is capturing right now.
  final bool audioActive;

  /// The current page's remembered camera/mic decision.
  final CefMediaSetting setting;

  /// Either device is capturing.
  bool get isCapturing => videoActive || audioActive;

  @override
  bool operator ==(Object other) =>
      other is CefMediaState &&
      other.videoActive == videoActive &&
      other.audioActive == audioActive &&
      other.setting == setting;

  @override
  int get hashCode => Object.hash(videoActive, audioActive, setting);

  @override
  String toString() =>
      'CefMediaState(video: $videoActive, audio: $audioActive, $setting)';
}

/// The live frame surface backing a session: the global IOSurface id its
/// off-screen CVPixelBuffer is wrapped over, plus the surface's PHYSICAL
/// (Retina) pixel dimensions. Delivered by [CefWebController.onSurface] on each
/// (re)allocation (create + every resize) and pullable on demand via
/// [CefWebController.getFrameSurface]. A consumer resolves the surface by id
/// (e.g. `IOSurfaceLookup`) to mirror the live page pixels off-Flutter; it must
/// re-read on every change, since a resize frees the old surface.
class CefSurfaceInfo {
  const CefSurfaceInfo({
    required this.surfaceId,
    required this.width,
    required this.height,
  });

  /// The global IOSurface id, resolvable cross-process. 0 before allocation.
  final int surfaceId;

  /// Physical (Retina) pixel width of the surface.
  final int width;

  /// Physical (Retina) pixel height of the surface.
  final int height;

  @override
  String toString() => 'CefSurfaceInfo($surfaceId, ${width}x$height)';
}

/// A cookie returned by [CefWebController.getCookies].
class CefCookie {
  const CefCookie({
    required this.name,
    required this.value,
    required this.domain,
    required this.path,
    required this.secure,
    required this.httpOnly,
  });

  /// Parse one cookie from the host's JSON.
  factory CefCookie.fromJson(Map<String, dynamic> j) => CefCookie(
        name: j['name'] as String? ?? '',
        value: j['value'] as String? ?? '',
        domain: j['domain'] as String? ?? '',
        path: j['path'] as String? ?? '',
        secure: j['secure'] as bool? ?? false,
        httpOnly: j['httpOnly'] as bool? ?? false,
      );

  final String name;
  final String value;
  final String domain;
  final String path;
  final bool secure;
  final bool httpOnly;

  @override
  String toString() => 'CefCookie($name=$value; domain=$domain path=$path'
      '${secure ? ' secure' : ''}${httpOnly ? ' httpOnly' : ''})';
}

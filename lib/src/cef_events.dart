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

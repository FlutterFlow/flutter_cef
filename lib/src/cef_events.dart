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

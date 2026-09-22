import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// The Windows host carries a copy of the macOS document_start.h (each federated
// package builds standalone, so the header can't be shared). The copies may
// differ only in their leading comment block.
void main() {
  test('document_start.h is identical on macOS and Windows', () {
    String body(String path) => File(path)
        .readAsLinesSync()
        .skipWhile((l) => l.startsWith('//'))
        .join('\n');
    expect(
      body('packages/flutter_cef_windows/native/cef_host/document_start.h'),
      body('packages/flutter_cef_macos/native/cef_host/document_start.h'),
    );
  });
}

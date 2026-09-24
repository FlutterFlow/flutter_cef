import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/protocol/generate.dart';
import '../tool/protocol/spec.dart';

// The cef_host wire protocol is defined once, in tool/protocol/spec.dart, and
// generated into each package. These tests keep it that way.
void main() {
  test('every opcode has one number and one name', () {
    final codes = <int, String>{};
    final names = <String>{};
    for (final o in ops) {
      expect(o.code, inInclusiveRange(1, 0xff), reason: o.name);
      expect(o.platforms, isNotEmpty, reason: o.name);
      expect(codes[o.code], isNull,
          reason: '${hex(o.code)} is both ${codes[o.code]} and ${o.name}');
      expect(names.add(o.name), isTrue, reason: 'duplicate name ${o.name}');
      codes[o.code] = o.name;
    }
    expect(protocolVersions.keys.toSet(), Platform.values.toSet());
  });

  test('the generated files match the spec', () {
    generatedFiles('.').forEach((path, content) {
      expect(File(path).readAsStringSync(), content,
          reason: '$path is stale: run dart run tool/protocol/generate.dart');
    });
  });

  test('no opcode or protocol version is defined outside the generated files',
      () {
    final generated = {macosHeaderPath, macosSwiftPath, windowsHeaderPath};
    final definition = RegExp(
      r'kOp\w+\s*=\s*0x'
      r'|\bop[A-Z]\w*\s*:\s*UInt8\s*=\s*0x'
      r'|kCefHostProtocolVersion\s*=\s*\d'
      r'|static\s+let\s+protocolVersion\b',
    );
    final offenders = <String>[];
    for (final entity in Directory('packages').listSync(recursive: true)) {
      if (entity is! File) continue;
      final path = entity.path;
      if (!RegExp(r'\.(mm|cc|cpp|h|swift)$').hasMatch(path)) continue;
      if (path.contains('/build/') || path.contains('/prebuilt/')) continue;
      if (generated.contains(path)) continue;
      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (definition.hasMatch(lines[i])) offenders.add('$path:${i + 1}');
      }
    }
    expect(offenders, isEmpty,
        reason: 'add opcodes to tool/protocol/spec.dart instead');
  });
}

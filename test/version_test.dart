import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kostoma/kostoma.dart';

/// The version is written in three places. A release with any of them out
/// of step would tell people the wrong thing about what they installed.
void main() {
  test('the version is the same everywhere it is written', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final changelog = File('CHANGELOG.md').readAsStringSync();

    final versionLine = RegExp(r'^version:\s*(\S+)', multiLine: true);
    final heading = RegExp(r'^## \[?(\d+\.\d+\.\d+)', multiLine: true);

    expect(versionLine.firstMatch(pubspec)?.group(1), kostomaSdkVersion);
    expect(heading.firstMatch(changelog)?.group(1), kostomaSdkVersion);
  });
}

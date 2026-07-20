import 'dart:convert';
import 'dart:io';

import 'package:lazyperson/models/models.dart';

const fixtureSymbols = ['002138', '600519', '300750', '000001'];

String _fixturePath(String name) => 'test/fixtures/$name';

Object? loadFixture(String name) =>
    jsonDecode(File(_fixturePath(name)).readAsStringSync());

List<KlineBar> loadBars(String symbol) => (loadFixture('bars_$symbol.json') as List)
    .map((row) => KlineBar.fromJson((row as Map).cast<String, Object?>()))
    .toList();

/// 数值对拍：后端 golden 已四舍五入到 6 位小数，绝对+相对双容差
void expectClose(double? actual, double? expected, String context) {
  if (expected == null || actual == null) {
    if (expected != actual) {
      throw StateError('$context: expected $expected, got $actual');
    }
    return;
  }
  final diff = (actual - expected).abs();
  final ok = diff <= 1e-4 ||
      (expected != 0 && (diff / expected.abs()) <= 1e-7);
  if (!ok) {
    throw StateError('$context: expected $expected, got $actual (diff $diff)');
  }
}

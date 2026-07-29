/// symbol 归一化与市场判断，移植自 backend/app/utils.py。
library;

String normalizeSymbol(String symbol) {
  var clean = symbol.trim().toUpperCase();
  for (final suffix in const ['.SH', '.SZ', '.BJ', '.SS', '.US']) {
    clean = clean.replaceAll(suffix, '');
  }
  return clean;
}

final _alphaPattern = RegExp(r'^[A-Z]+$');
final _digitPattern = RegExp(r'^\d+$');

String guessMarket(String symbol) {
  final clean = normalizeSymbol(symbol);
  if (clean.endsWith('-USD')) return 'CRYPTO';
  if (clean.endsWith('=F')) return 'FUT';
  if (clean.endsWith('=X')) return 'FX';
  if (_alphaPattern.hasMatch(clean) && clean.isNotEmpty && clean.length <= 5) {
    return 'US';
  }
  if (clean.startsWith('5') || clean.startsWith('6') || clean.startsWith('9')) {
    return 'SH';
  }
  if (clean.startsWith('0') || clean.startsWith('2') || clean.startsWith('3')) {
    return 'SZ';
  }
  if (clean.startsWith('4') || clean.startsWith('8')) return 'BJ';
  return '';
}

bool isAShareSymbol(String symbol) {
  final clean = normalizeSymbol(symbol);
  return _digitPattern.hasMatch(clean) &&
      const {'SH', 'SZ', 'BJ'}.contains(guessMarket(clean));
}

/// 总市值统一为亿元（对齐 backend normalizers.py::_market_cap_yi）：
/// 东财口径是元（>1e6 必为元），腾讯口径已是亿元。
double? marketCapYi(double? value) {
  if (value == null) return null;
  return value > 1e6 ? value / 1e8 : value;
}

double? safeDouble(Object? value) {
  if (value == null) return null;
  if (value is num) return value.isFinite ? value.toDouble() : null;
  final text = value.toString().trim();
  if (text.isEmpty || text == '-') return null;
  return double.tryParse(text);
}

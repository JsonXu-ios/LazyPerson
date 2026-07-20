class ProviderError implements Exception {
  final String message;
  final String source;

  const ProviderError(this.message, [this.source = '']);

  @override
  String toString() => source.isEmpty ? message : '$source: $message';
}

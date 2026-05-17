String contentDispositionForDownload(String fileName) {
  final fallback = _asciiFallback(fileName);
  final encoded = Uri.encodeComponent(fileName);
  return "attachment; filename=\"$fallback\"; filename*=UTF-8''$encoded";
}

String _asciiFallback(String fileName) {
  final extension = fileName.toLowerCase().endsWith(".epub") ? ".epub" : "";
  final base = extension.isEmpty
      ? fileName
      : fileName.substring(0, fileName.length - extension.length);
  final sanitized = base
      .replaceAll(RegExp(r'[^A-Za-z0-9._ -]'), "_")
      .replaceAll(RegExp(r"_+"), "_")
      .replaceAll(RegExp(r"\s+"), " ")
      .trim();
  final safeBase = sanitized.replaceAll(RegExp(r'^[._ -]+|[._ -]+$'), "");
  if (safeBase.isEmpty) {
    return "download$extension";
  }
  return "$safeBase$extension";
}

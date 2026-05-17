List<int> parseVolumeSelection(String input, int volumeCount) {
  if (volumeCount < 0) {
    throw ArgumentError.value(volumeCount, "volumeCount");
  }
  if (volumeCount == 0) return const <int>[];

  final text = input.trim();
  if (text.isEmpty || text == "0") {
    return List<int>.generate(volumeCount, (index) => index);
  }

  final indexes = <int>{};
  final normalized = text
      .replaceAll("，", ",")
      .replaceAll("、", ",")
      .replaceAll("；", ",")
      .replaceAll(";", ",")
      .replaceAll(RegExp(r"\s+"), ",");

  for (final rawPart in normalized.split(",")) {
    final part = rawPart.trim();
    if (part.isEmpty) continue;

    final range = part.split("-");
    if (range.length == 1) {
      indexes.add(_parseOneBasedIndex(range.first, volumeCount));
      continue;
    }
    if (range.length != 2) {
      throw FormatException("无效的分卷范围: $part");
    }

    var start = _parseOneBasedIndex(range.first, volumeCount);
    var end = _parseOneBasedIndex(range.last, volumeCount);
    if (start > end) {
      final temp = start;
      start = end;
      end = temp;
    }
    for (int index = start; index <= end; index++) {
      indexes.add(index);
    }
  }

  if (indexes.isEmpty) {
    return List<int>.generate(volumeCount, (index) => index);
  }

  final result = indexes.toList()..sort();
  return result;
}

int _parseOneBasedIndex(String input, int volumeCount) {
  final value = int.tryParse(input.trim());
  if (value == null) {
    throw FormatException("分卷序号必须是数字: $input");
  }
  if (value < 1 || value > volumeCount) {
    throw RangeError.range(value, 1, volumeCount, "volume");
  }
  return value - 1;
}

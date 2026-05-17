class VolumeUtil {
  static const Map<String, int> _chineseNumberMap = {
    '一': 1,
    '二': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
    '十': 10,
    '十一': 11,
    '十二': 12,
    '十三': 13,
    '十四': 14,
    '十五': 15,
    '十六': 16,
    '十七': 17,
    '十八': 18,
    '十九': 19,
    '二十': 20,
    '二十一': 21,
    '二十二': 22,
    '二十三': 23,
    '二十四': 24,
    '二十五': 25,
    '二十六': 26,
    '二十七': 27,
    '二十八': 28,
    '二十九': 29,
    '三十': 30,
  };

  static num? getSeriesIndex(String volumeName) {
    return _getSeriesIndexByLastNum(volumeName) ??
        _getSeriesIndexByVolumeName(volumeName);
  }

  static double? _getSeriesIndexByLastNum(String volumeName) {
    var reg = RegExp(".*\\s(\\d+(?:\\.\\d)?)\$");
    var match = reg.firstMatch(volumeName);
    if (match != null && match.groupCount > 0) {
      return double.tryParse(match.group(1)!);
    }
    return null;
  }

  static int? _getSeriesIndexByVolumeName(String volumeName) {
    var reg = RegExp("第([一二三四五六七八九十]+)[卷话章]\$");
    var match = reg.firstMatch(volumeName);
    if (match != null && match.groupCount > 0) {
      var chineseNumber = match.group(1);
      return _chineseNumberMap[chineseNumber];
    }
    return null;
  }
}

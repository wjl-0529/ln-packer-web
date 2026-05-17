import 'package:ln_packer_web/web/volume_selection.dart';
import 'package:test/test.dart';

void main() {
  group("parseVolumeSelection", () {
    test("selects all for empty or zero input", () {
      expect(parseVolumeSelection("", 3), [0, 1, 2]);
      expect(parseVolumeSelection("0", 3), [0, 1, 2]);
    });

    test("supports single indexes, ranges, Chinese punctuation, and sorting",
        () {
      expect(parseVolumeSelection("3，1-2 2", 4), [0, 1, 2]);
      expect(parseVolumeSelection("4-2", 5), [1, 2, 3]);
    });

    test("rejects invalid indexes", () {
      expect(() => parseVolumeSelection("x", 3), throwsFormatException);
      expect(() => parseVolumeSelection("4", 3), throwsRangeError);
    });
  });
}

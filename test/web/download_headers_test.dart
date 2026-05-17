import 'package:ln_packer_web/web/download_headers.dart';
import 'package:test/test.dart';

void main() {
  group("contentDispositionForDownload", () {
    test("uses ASCII fallback and UTF-8 filename for Chinese names", () {
      final header = contentDispositionForDownload("我和班上第二可爱的女生成为朋友.epub");

      expect(header, contains('filename="download.epub"'));
      expect(header, contains("filename*=UTF-8''"));
      expect(header, isNot(contains('filename="我和班上第二可爱的女生成为朋友.epub"')));
      expect(header.runes.every((codePoint) => codePoint <= 0x7f), isTrue);
    });

    test("keeps safe ASCII names in fallback", () {
      final header = contentDispositionForDownload("novel-01.epub");

      expect(header, contains('filename="novel-01.epub"'));
      expect(header, contains("filename*=UTF-8''novel-01.epub"));
    });
  });
}

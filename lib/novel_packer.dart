import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:ln_packer_web/assets/assets.dart';
import 'package:ln_packer_web/epub_packer/epub_navigator.dart';
import 'package:ln_packer_web/epub_packer/epub_packer.dart';
import 'package:ln_packer_web/light_novel/base/light_novel_cover_detector.dart';
import 'package:ln_packer_web/light_novel/base/light_novel_model.dart';
import 'package:ln_packer_web/light_novel/base/light_novel_source.dart';
import 'package:ln_packer_web/light_novel/bili_novel/bili_novel_source.dart';
import 'package:ln_packer_web/light_novel/wenku_novel/wenku_novel_source.dart';
import 'package:ln_packer_web/log.dart';
import 'package:ln_packer_web/pack_run_context.dart';
import 'package:ln_packer_web/pack_argument.dart';
import 'package:ln_packer_web/util/cancellation.dart';
import 'package:ln_packer_web/util/volume_util.dart';
import 'package:ln_packer_web/util/html_util.dart';
import 'package:ln_packer_web/util/sequence.dart';
import 'package:console/console.dart';
import 'package:html/dom.dart';
import 'package:path/path.dart' as path;

typedef PackLogCallback = void Function(String message);
typedef PackProgressCallback = void Function(PackProgress progress);
typedef PackCancelCheck = bool Function();

class PackCanceledException implements Exception {
  final String message;

  const PackCanceledException([this.message = "打包任务已取消"]);

  @override
  String toString() => message;
}

class PackProgress {
  final String phase;
  final String message;
  final int completed;
  final int total;
  final double percent;
  final String? volumeName;
  final String? chapterName;
  final int activeChapterCount;

  PackProgress({
    required this.phase,
    required this.message,
    required this.completed,
    required this.total,
    double? percent,
    this.volumeName,
    this.chapterName,
    this.activeChapterCount = 0,
  }) : percent = percent ?? _completedPercent(completed, total);

  Map<String, Object?> toJson() {
    return {
      "phase": phase,
      "message": message,
      "completed": completed,
      "total": total,
      "percent": percent,
      "volumeName": volumeName,
      "chapterName": chapterName,
      "activeChapterCount": activeChapterCount,
    };
  }
}

double _completedPercent(int completed, int total) {
  if (total <= 0) return 0;
  return (completed / total * 100).clamp(0, 100).toDouble();
}

class NovelPacker {
  static final List<LightNovelSource> sources = [
    BiliNovelSource(),
    WenkuNovelSource()
  ];

  String url;
  LightNovelSource lightNovelSource;
  final PackRunContext? _runContext;

  final Sequence _imageSequence = Sequence();
  final Sequence _chapterSequence = Sequence();

  String? _outputDirectory;
  PackLogCallback? _onLog;
  PackProgressCallback? _onProgress;
  PackCancelCheck? _isCanceled;
  int _completedChapters = 0;
  int _totalChapters = 0;
  int _activeChapters = 0;
  double _lastPercent = 0;
  final Map<Chapter, double> _chapterCredits = HashMap.identity();
  final List<File> _outputFiles = [];

  late Novel novel;
  late Catalog catalog;

  NovelPacker._(this.lightNovelSource, this.url, [this._runContext]);

  factory NovelPacker.fromUrl(String url, {PackRunContext? runContext}) {
    for (var source in sources) {
      if (source.supportUrl(url)) {
        return NovelPacker._(_newSource(source, runContext), url, runContext);
      }
    }
    throw "Unsupported url: $url";
  }

  static LightNovelSource _newSource(
    LightNovelSource source,
    PackRunContext? runContext,
  ) {
    if (source is BiliNovelSource) {
      return BiliNovelSource(runContext: runContext);
    }
    if (source is WenkuNovelSource) {
      return WenkuNovelSource(runContext: runContext);
    }
    return source;
  }

  Future<Novel> init({
    Function(Novel novel)? novelCallback,
    Function(Catalog catalog)? catalogCallback,
  }) async {
    novel = await getNovel();
    novelCallback?.call(novel);
    catalog = await getCatalog();
    catalogCallback?.call(catalog);
    return novel;
  }

  Future<Novel> getNovel() async {
    return lightNovelSource.getNovel(url).then((novel) => this.novel = novel);
  }

  Future<Catalog> getCatalog() async {
    return lightNovelSource
        .getNovelCatalog(novel)
        .then((catalog) => this.catalog = catalog);
  }

  Future<List<File>> pack(
    PackArgument arg, {
    String? outputDirectory,
    PackLogCallback? onLog,
    PackProgressCallback? onProgress,
    PackCancelCheck? isCanceled,
    int chapterConcurrency = 6,
    int imageConcurrency = 8,
  }) async {
    _outputDirectory = outputDirectory;
    _onLog = onLog;
    _onProgress = onProgress;
    _isCanceled = isCanceled;
    _completedChapters = 0;
    _activeChapters = 0;
    _lastPercent = 0;
    _chapterCredits.clear();
    _totalChapters = arg.packVolumes.fold<int>(
      0,
      (total, volume) => total + volume.chapters.length,
    );
    _outputFiles.clear();

    if (_outputDirectory != null) {
      Directory(_outputDirectory!).createSync(recursive: true);
    }

    _emitProgress(
      phase: "packing",
      message: "准备打包 ${arg.packVolumes.length} 个分卷",
    );

    try {
      _throwIfCanceled();
      if (!arg.combineVolume) {
        for (var volume in arg.packVolumes) {
          _throwIfCanceled();
          _emitLog("开始打包 ${volume.catalog.novel.title} ${volume.volumeName}");
          _imageSequence.reset();
          _chapterSequence.reset();
          await _packVolume(
            volume,
            arg.addChapterTitle,
            chapterConcurrency,
            imageConcurrency,
          );
          _emitLog("打包完成 ${volume.catalog.novel.title} ${volume.volumeName}");
        }
      } else {
        _throwIfCanceled();
        // 合并分卷
        String title = _sanitizeFileName(novel.title);
        String epubPath = _resolveOutputPath(path.join(title, "$title.epub"));
        _emitLog("EPUB file: $epubPath");
        await _combineVolume(
          epubPath,
          arg,
          chapterConcurrency,
          imageConcurrency,
        );
      }
      _throwIfCanceled();
      _emitProgress(
        phase: "completed",
        message: "全部 EPUB 文件已生成",
        percent: 100,
      );
      return List.unmodifiable(_outputFiles);
    } finally {
      _outputDirectory = null;
      _onLog = null;
      _onProgress = null;
      _isCanceled = null;
    }
  }

  Future<void> _combineVolume(
    String path,
    PackArgument arg,
    int chapterConcurrency,
    int imageConcurrency,
  ) async {
    _throwIfCanceled();
    EpubPacker packer = EpubPacker(path);
    packer.docTitle = novel.title;
    packer.creator = novel.author;
    packer.source = novel.url;
    packer.publisher = novel.publisher;
    packer.subjects = novel.tags ?? [];
    packer.description = novel.description;
    // 封面使用小说封面
    Uint8List coverData = novel.coverUrl == null
        ? Uint8List(0)
        : await _getSingleImage(novel.coverUrl!);
    _throwIfCanceled();
    String coverName =
        "images/${_imageSequence.next.toString().padLeft(6, '0')}.jpg";
    packer.addImage(name: "OEBPS/$coverName", data: coverData);
    packer.cover = coverName;

    if (arg.addChapterTitle) {
      packer.addStylesheet(styleCss());
    }

    for (Volume volume in arg.packVolumes) {
      _throwIfCanceled();
      _emitLog("正在处理: ${volume.volumeName}");
      _emitProgress(
        phase: "volume",
        message: "正在处理分卷: ${volume.volumeName}",
        volumeName: volume.volumeName,
      );
      NavPoint volumeNavPoint = NavPoint(volume.volumeName);
      List<Document> chapterDocuments = await _mapConcurrent(
        volume.chapters,
        chapterConcurrency,
        (chapter) => _resolveChapter(
          chapter,
          packer,
          arg.addChapterTitle,
          imageConcurrency,
        ),
      );
      for (int i = 0; i < chapterDocuments.length; i++) {
        _throwIfCanceled();
        Chapter chapter = volume.chapters[i];
        Document document = chapterDocuments[i];
        _addTitle(document, chapter.chapterName);
        String html = _closeTag(document);
        html = _appendXmlDeclare(html);
        String name =
            "chapter${_chapterSequence.next.toString().padLeft(6, "0")}.xhtml";
        packer.addChapter(
          addNavPoint: false,
          name: "OEBPS/$name",
          title: chapter.chapterName,
          chapterContent: html,
        );
        NavPoint chapterNavPoint = NavPoint(chapter.chapterName, src: name);
        volumeNavPoint.addChild(chapterNavPoint);
        if (i == 0) {
          volumeNavPoint.src = name;
        }
      }
      packer.addNavPoint(volumeNavPoint);
      _emitLog("处理完成: ${volume.volumeName}");
    }
    _throwIfCanceled();
    _emitProgress(
      phase: "writing",
      message: "正在写入 EPUB 文件",
      percent: _writingPercent(),
    );
    packer.pack();
    _emitProgress(
      phase: "writing",
      message: "EPUB 文件写入完成",
      percent: _writtenPercent(),
    );
    _recordOutput(packer);
  }

  Future<Document> _resolveChapter(
    Chapter chapter,
    EpubPacker packer,
    bool addChapterTitle, [
    int imageConcurrency = 8,
    LightNovelCoverDetector? detector,
  ]) async {
    _throwIfCanceled();
    _activeChapters++;
    _setChapterCredit(chapter, 0.05);
    _emitProgress(
      phase: "chapter-start",
      message: "正在处理: ${chapter.chapterName}",
      volumeName: chapter.volume.volumeName,
      chapterName: chapter.chapterName,
    );
    try {
      Document doc = await lightNovelSource.getNovelChapter(chapter);
      _throwIfCanceled();
      _setChapterCredit(chapter, 0.35);
      _emitProgress(
        phase: "chapter-body",
        message: "已获取正文: ${chapter.chapterName}",
        volumeName: chapter.volume.volumeName,
        chapterName: chapter.chapterName,
      );
      // 处理图片资源
      await _resolveImages(doc, packer, detector, chapter, imageConcurrency);
      _throwIfCanceled();
      _setChapterCredit(chapter, 0.95);
      _emitProgress(
        phase: "chapter-finalize",
        message: "正在整理章节: ${chapter.chapterName}",
        volumeName: chapter.volume.volumeName,
        chapterName: chapter.chapterName,
      );

      // 添加章节标题
      if (addChapterTitle) {
        doc.head!.append(Element.html(
          '<link rel="stylesheet" type="text/css" href="styles/style.css">',
        ));
        var firstChild = doc.body!.firstChild;
        Node chapterTitle = Element.html(
          '<div class="chapter-title">${chapter.chapterName}</div>',
        );
        doc.body!.insertBefore(chapterTitle, firstChild);
      }
      logger.i("OK ${chapter.volume.volumeName} ${chapter.chapterName}");
      _chapterCredits.remove(chapter);
      _completedChapters++;
      _emitProgress(
        phase: "chapter-completed",
        message: "处理完成: ${chapter.chapterName}",
        volumeName: chapter.volume.volumeName,
        chapterName: chapter.chapterName,
      );
      return doc;
    } finally {
      _activeChapters--;
      if (_activeChapters < 0) {
        _activeChapters = 0;
      }
    }
  }

  Future<Uint8List> _getSingleImage(String src) async {
    try {
      return lightNovelSource.getImage(src);
    } catch (e) {
      return Uint8List(0);
    }
  }

  Future<void> _packVolume(
    Volume volume,
    bool addChapterTitle,
    int chapterConcurrency,
    int imageConcurrency,
  ) async {
    _throwIfCanceled();
    _emitLog("开始打包 ${volume.volumeName}...");
    _emitProgress(
      phase: "volume",
      message: "正在处理分卷: ${volume.volumeName}",
      volumeName: volume.volumeName,
    );
    EpubPacker packer = EpubPacker(_getEpubName(volume));
    packer.docTitle = "${volume.catalog.novel.title} ${volume.volumeName}";
    if (volume.volumeName.startsWith(volume.catalog.novel.title)) {
      packer.docTitle = volume.volumeName;
    }
    packer.creator = volume.catalog.novel.author;
    packer.source = novel.url;
    packer.publisher = novel.publisher;
    packer.subjects = novel.tags ?? [];
    packer.description = novel.description;
    // 当识别出丛书编号时才设置丛书名 否则丛书编号会被当成1
    packer.calibreSeriesIndex = VolumeUtil.getSeriesIndex(volume.volumeName);
    if (packer.calibreSeriesIndex != null) {
      packer.calibreSeries = volume.catalog.novel.title;
    }

    LightNovelCoverDetector detector = LightNovelCoverDetector();

    if (addChapterTitle) {
      packer.addStylesheet(styleCss());
    }

    List<Document> chapterDocuments = await _mapConcurrent(
      volume.chapters,
      chapterConcurrency,
      (chapter) => _resolveChapter(
        chapter,
        packer,
        addChapterTitle,
        imageConcurrency,
        detector,
      ),
    );

    // 添加章节资源
    for (int i = 0; i < chapterDocuments.length; i++) {
      _throwIfCanceled();
      var chapter = volume.chapters[i];
      var document = chapterDocuments[i];
      _addTitle(document, chapter.chapterName);
      String html = _closeTag(document);
      html = _appendXmlDeclare(html);
      packer.addChapter(
        name:
            "OEBPS/chapter${_chapterSequence.next.toString().padLeft(6, "0")}.xhtml",
        title: chapter.chapterName,
        chapterContent: html,
      );
    }

    // 设置封面
    await _resolveCover(volume, packer, detector);
    _throwIfCanceled();
    // 写出目标文件
    _emitProgress(
      phase: "writing",
      message: "正在写入 ${volume.volumeName}",
      volumeName: volume.volumeName,
      percent: _writingPercent(),
    );
    packer.pack();
    _emitProgress(
      phase: "writing",
      message: "${volume.volumeName} 写入完成",
      volumeName: volume.volumeName,
      percent: _writtenPercent(),
    );
    _recordOutput(packer);
  }

  Future<void> _resolveImages(
    Document doc,
    EpubPacker packer,
    LightNovelCoverDetector? detector,
    Chapter chapter,
    int imageConcurrency,
  ) async {
    _throwIfCanceled();
    // 下载图片 添加到epub中
    List<Element> imgList = doc.querySelectorAll("img");
    if (imgList.isNotEmpty) {
      _setChapterCredit(chapter, 0.50);
      _emitProgress(
        phase: "images",
        message: "正在处理图片: ${chapter.chapterName}",
        volumeName: chapter.volume.volumeName,
        chapterName: chapter.chapterName,
      );
    } else {
      _setChapterCredit(chapter, 0.90);
      _emitProgress(
        phase: "images",
        message: "无需处理图片: ${chapter.chapterName}",
        volumeName: chapter.volume.volumeName,
        chapterName: chapter.chapterName,
      );
      HTMLUtil.wrapDuoKanImage(doc.body!);
      return;
    }
    var processedImages = 0;
    List<Pair<Element, Uint8List>?> pairList = await _mapConcurrent(
      imgList,
      imageConcurrency,
      (img) async {
        final pair = await _resolveSingleImage(img, packer, detector);
        processedImages++;
        final imageCredit = 0.50 + (0.40 * processedImages / imgList.length);
        _setChapterCredit(chapter, imageCredit);
        _emitProgress(
          phase: "images",
          message:
              "正在处理图片: ${chapter.chapterName} ($processedImages/${imgList.length})",
          volumeName: chapter.volume.volumeName,
          chapterName: chapter.chapterName,
        );
        return pair;
      },
    );
    for (Pair<Element, Uint8List>? pair in pairList) {
      _throwIfCanceled();
      if (pair == null) continue;
      Element img = pair.v1;
      Uint8List imageData = pair.v2;
      String name = "${_imageSequence.next.toString().padLeft(6, '0')}.jpg";
      String relativeSrc = "images/$name";
      packer.addImage(name: "OEBPS/$relativeSrc", data: imageData);
      String? src = img.attributes["src"];
      img.attributes["src"] = relativeSrc;
      try {
        detector?.add("OEBPS/$relativeSrc", imageData);
      } on UnsupportedImageException catch (e) {
        _emitLog("$src ${e.message}");
      }
    }

    HTMLUtil.wrapDuoKanImage(doc.body!);
  }

  Future<Pair<Element, Uint8List>?> _resolveSingleImage(
    Element img,
    EpubPacker packer,
    LightNovelCoverDetector? detector,
  ) async {
    _throwIfCanceled();
    String? src = img.attributes["src"];
    if (src == null || src.isEmpty) {
      return null;
    }
    Uint8List imageData = await _getSingleImage(src);
    _throwIfCanceled();
    if (imageData.isEmpty) {
      _emitLog("$src 图片下载失败");
      return null;
    }
    return Pair(img, imageData);
  }

  Future<void> _resolveCover(
    Volume volume,
    EpubPacker packer,
    LightNovelCoverDetector coverDetector,
  ) async {
    _throwIfCanceled();
    // 优先使用目录中的封面 否则自动检测
    if (volume.cover != null) {
      Uint8List coverData =
          await _getSingleImage(volume.cover!).catchError((e) {
        throw "下载封面失败 ${volume.cover}\n$e";
      });
      _throwIfCanceled();
      String coverName =
          "images/${_imageSequence.next.toString().padLeft(6, '0')}.jpg";
      packer.addImage(name: "OEBPS/$coverName", data: coverData);
      packer.cover = coverName;
    } else {
      String? cover = coverDetector.detectCover();
      if (cover != null) {
        packer.cover = cover.replaceFirst("OEBPS/", "");
      }
    }
  }

  String _getEpubName(Volume volume) {
    String title = _sanitizeFileName(volume.catalog.novel.title);
    String volumeName = _sanitizeFileName(volume.volumeName);
    String fileName;
    if (volumeName == "") {
      fileName = "$title.epub";
    } else if (volumeName.startsWith(title)) {
      fileName = "$volumeName.epub";
    } else {
      fileName = "$title $volumeName.epub";
    }
    return _resolveOutputPath(path.join(title, fileName));
  }

  String _resolveOutputPath(String relativePath) {
    if (_outputDirectory == null) {
      return relativePath;
    }
    return path.join(_outputDirectory!, relativePath);
  }

  void _recordOutput(EpubPacker packer) {
    File file = File(packer.epubFilePath);
    _outputFiles.add(file);
    _emitLog("打包完成: ${packer.absolutePath}");
  }

  void _emitLog(String message) {
    logger.i(message);
    _onLog?.call(message);
    if (_onLog == null) {
      Console.write("$message\n");
    }
  }

  void _emitProgress({
    required String phase,
    required String message,
    String? volumeName,
    String? chapterName,
    double? percent,
  }) {
    _onProgress?.call(PackProgress(
      phase: phase,
      message: message,
      completed: _completedChapters,
      total: _totalChapters,
      percent: _progressPercent(percent),
      volumeName: volumeName,
      chapterName: chapterName,
      activeChapterCount: _activeChapters,
    ));
  }

  void _setChapterCredit(Chapter chapter, double credit) {
    final current = _chapterCredits[chapter] ?? 0;
    final next = credit.clamp(0, 0.95).toDouble();
    if (next > current) {
      _chapterCredits[chapter] = next;
    }
  }

  double _progressPercent(double? explicitPercent) {
    final next = explicitPercent ?? _estimatedPercent();
    final bounded = next.clamp(0, 100).toDouble();
    if (bounded < _lastPercent) {
      return _lastPercent;
    }
    _lastPercent = bounded;
    return bounded;
  }

  double _estimatedPercent() {
    if (_totalChapters <= 0) return 0;
    final activeCredit =
        _chapterCredits.values.fold<double>(0, (sum, credit) => sum + credit);
    final percent = (_completedChapters + activeCredit) / _totalChapters * 100;
    return percent.clamp(0, 97).toDouble();
  }

  double _writingPercent() {
    if (_totalChapters <= 0) return 98;
    final percent = (_completedChapters + 0.98) / _totalChapters * 100;
    return percent.clamp(0, 98).toDouble();
  }

  double _writtenPercent() {
    if (_totalChapters <= 0) return 99;
    final percent = (_completedChapters + 0.99) / _totalChapters * 100;
    return percent.clamp(0, 99).toDouble();
  }

  void _throwIfCanceled() {
    if (_isCanceled?.call() == true || _runContext?.isCanceled == true) {
      throw const PackCanceledException();
    }
    try {
      _runContext?.throwIfCanceled();
    } on CancellationException {
      throw const PackCanceledException();
    }
  }

  Future<List<R>> _mapConcurrent<T, R>(
    List<T> items,
    int concurrency,
    Future<R> Function(T item) mapper,
  ) async {
    if (items.isEmpty) return <R>[];
    final limit = concurrency <= 0 ? items.length : concurrency;
    final results = List<R?>.filled(items.length, null);
    var nextIndex = 0;

    Future<void> worker() async {
      while (true) {
        _throwIfCanceled();
        final index = nextIndex;
        if (index >= items.length) return;
        nextIndex++;
        results[index] = await mapper(items[index]);
      }
    }

    final workerCount = limit > items.length ? items.length : limit;
    await Future.wait([
      for (var i = 0; i < workerCount; i++) worker(),
    ]);
    _throwIfCanceled();
    return [for (final result in results) result as R];
  }

  String _sanitizeFileName(String name) {
    var keywords = {":", "*", "?", "\"", "\\", "/", "<", ">", "|", "\\0", "　"};
    for (var keyword in keywords) {
      name = name.replaceAll(keyword, " ");
    }
    if (name.startsWith(".")) {
      name = name.substring(1);
    }
    if (name.endsWith(".")) {
      name = name.substring(0, name.length - 1);
    }
    // 替换连续空格为一个空格
    name = name.replaceAllMapped(RegExp("\\s+"), (_) => " ");
    return name.trim();
  }

  // 添加title元素
  _addTitle(Document document, String title) {
    var element = document.createElement("title");
    element.text = title;
    document.head?.append(element);
  }

  /// 将标签闭合
  String _closeTag(Document document) {
    String html = document.outerHtml;
    RegExp regExp = RegExp("(<(?:img|link).*?)>");
    Iterable<RegExpMatch> matches = regExp.allMatches(html);
    for (var match in matches) {
      String img = match.group(0)!;
      if (!img.endsWith("/>")) {
        String newImg = "${match.group(1)!}/>";
        html = html.replaceAll(img, newImg);
      }
    }
    return html;
  }

  String _appendXmlDeclare(String html) {
    String xmlDeclare = """<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN"
  "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
""";
    return xmlDeclare + html;
  }
}

class Pair<V1, V2> {
  V1 v1;
  V2 v2;

  Pair(this.v1, this.v2);
}

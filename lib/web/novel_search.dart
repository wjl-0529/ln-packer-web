import 'package:ln_packer_web/light_novel/bili_novel/bili_novel_source.dart';
import 'package:ln_packer_web/light_novel/wenku_novel/wenku_novel_source.dart';
import 'package:ln_packer_web/util/http_util.dart';
import 'package:fast_gbk/fast_gbk.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart';
import 'package:path/path.dart' as path;

class NovelSearchResult {
  final String source;
  final String sourceName;
  final String id;
  final String title;
  final String url;
  final String? author;
  final String? description;
  final String? coverUrl;

  NovelSearchResult({
    required this.source,
    required this.sourceName,
    required this.id,
    required this.title,
    required this.url,
    this.author,
    this.description,
    this.coverUrl,
  });

  Map<String, Object?> toJson() {
    return {
      "source": source,
      "sourceName": sourceName,
      "id": id,
      "title": title,
      "url": url,
      "author": author,
      "description": description,
      "coverUrl": coverUrl,
    };
  }
}

class NovelSearchService {
  Future<List<NovelSearchResult>> search({
    required String query,
    String source = "all",
    int page = 1,
  }) async {
    final keyword = query.trim();
    if (keyword.isEmpty) {
      throw const FormatException("搜索关键词不能为空");
    }
    final normalizedPage = page < 1 ? 1 : page;
    final selectedSource = source.trim().toLowerCase();
    final loaders = <Future<List<NovelSearchResult>> Function()>[];

    if (selectedSource == "all" ||
        selectedSource == "bili" ||
        selectedSource == "bilinovel") {
      loaders.add(() => _searchBili(keyword, normalizedPage));
    }
    if (selectedSource == "all" ||
        selectedSource == "wenku" ||
        selectedSource == "wenku8") {
      loaders.add(() => _searchWenku(keyword, normalizedPage));
    }
    if (loaders.isEmpty) {
      throw FormatException("不支持的搜索来源: $source");
    }

    final results = <List<NovelSearchResult>>[];
    final errors = <String>[];
    for (final loader in loaders) {
      try {
        results.add(await loader());
      } catch (error) {
        errors.add(_cleanError(error));
      }
    }
    if (results.every((group) => group.isEmpty) && errors.isNotEmpty) {
      throw StateError(errors.join("；"));
    }

    final seen = <String>{};
    return [
      for (final group in results)
        for (final item in group)
          if (seen.add("${item.source}:${item.id}")) item,
    ];
  }

  Future<List<NovelSearchResult>> _searchBili(String keyword, int page) async {
    final encodedQuery = Uri.encodeQueryComponent(keyword);
    final encodedPath = Uri.encodeComponent(keyword);
    final url = page <= 1
        ? "${BiliNovelSource.domain}/search.html?searchkey=$encodedQuery"
        : "${BiliNovelSource.domain}/search/${encodedPath}_$page.html";
    final html = await httpGetString(
      url,
      headers: {
        "User-Agent": BiliNovelSource.userAgent,
        "Accept-Language": "zh-CN,zh;q=0.9",
      },
      maxAttempts: 1,
    );
    _ensureSearchPageUsable(html, "哔哩轻小说");
    final doc = parse(html);
    return _extractResults(
      doc,
      source: "bili",
      sourceName: "哔哩轻小说",
      domain: BiliNovelSource.domain,
      linkPattern: RegExp(r"/novel/(\d+)(?:\.html|/)"),
    );
  }

  Future<List<NovelSearchResult>> _searchWenku(String keyword, int page) async {
    final encodedQuery = Uri.encodeQueryComponent(keyword, encoding: gbk);
    final url =
        "${WenkuNovelSource.domain}/modules/article/search.php?searchtype=articlename&searchkey=$encodedQuery&page=$page";
    final html = await httpGetString(
      url,
      headers: {
        "User-Agent": WenkuNovelSource.userAgent,
      },
      codec: gbk,
      maxAttempts: 1,
    );
    _ensureSearchPageUsable(html, "轻小说文库");
    final doc = parse(html);
    return _extractResults(
      doc,
      source: "wenku",
      sourceName: "轻小说文库",
      domain: WenkuNovelSource.domain,
      linkPattern: RegExp(r"/(?:book/(\d+)\.htm|novel/\d+/(\d+)/)"),
    );
  }

  List<NovelSearchResult> _extractResults(
    Document doc, {
    required String source,
    required String sourceName,
    required String domain,
    required RegExp linkPattern,
  }) {
    final results = <NovelSearchResult>[];
    final seen = <String>{};

    for (final link in doc.querySelectorAll("a[href]")) {
      final href = link.attributes["href"];
      if (href == null) continue;
      final match = linkPattern.firstMatch(href);
      if (match == null) continue;

      final id = match.group(1) ?? match.group(2);
      if (id == null || !seen.add(id)) continue;

      final resolvedUrl = _resolveUrl(domain, href);
      final root = _resultRoot(link);
      final title = _pickTitle(root, link);
      if (title.isEmpty || title.length > 80) continue;

      results.add(NovelSearchResult(
        source: source,
        sourceName: sourceName,
        id: id,
        title: title,
        url: resolvedUrl,
        author: _pickAuthor(root),
        description: _pickDescription(root),
        coverUrl: _pickCover(root, domain),
      ));
    }

    return results.take(20).toList();
  }

  Element _resultRoot(Element link) {
    Element current = link;
    for (int i = 0; i < 5; i++) {
      final parent = current.parent;
      if (parent == null || parent.localName == "body") break;
      final textLength = parent.text.trim().length;
      final hasImage = parent.querySelector("img") != null;
      if (hasImage || textLength > 30) {
        current = parent;
      }
      if (parent.localName == "tr" ||
          parent.localName == "li" ||
          parent.classes.contains("book-layout") ||
          parent.classes.contains("bookbox")) {
        return parent;
      }
    }
    return current;
  }

  String _pickTitle(Element root, Element link) {
    final candidates = [
      root.querySelector(".book-title")?.text,
      root.querySelector("h3")?.text,
      root.querySelector("h4")?.text,
      link.attributes["title"],
      link.text,
    ];
    for (final candidate in candidates) {
      final text = _clean(candidate);
      if (text.isNotEmpty) return text;
    }
    return "";
  }

  String? _pickAuthor(Element root) {
    final selectors = [
      ".book-rand-a span",
      ".author",
      ".book-author",
      "[class*=author]",
    ];
    for (final selector in selectors) {
      final text = _clean(root.querySelector(selector)?.text);
      if (text.isNotEmpty) {
        return text.replaceFirst(RegExp(r"^作者[:：]\s*"), "");
      }
    }

    final match = RegExp(r"作者[:：]\s*([^\s/｜|]+)").firstMatch(root.text);
    return _clean(match?.group(1)).isEmpty ? null : _clean(match?.group(1));
  }

  String? _pickDescription(Element root) {
    final selectors = [
      ".book-summary",
      ".book-desc",
      ".intro",
      ".desc",
      ".review",
      "p",
    ];
    for (final selector in selectors) {
      final text = _clean(root.querySelector(selector)?.text);
      if (text.length > 8) return text;
    }
    final text = _clean(root.text);
    if (text.length > 20) {
      return text.length > 160 ? "${text.substring(0, 160)}..." : text;
    }
    return null;
  }

  String? _pickCover(Element root, String domain) {
    final src = root.querySelector("img")?.attributes["src"] ??
        root.querySelector("img")?.attributes["data-src"];
    if (src == null || src.trim().isEmpty) return null;
    return _resolveUrl(domain, src);
  }

  String _resolveUrl(String domain, String href) {
    final uri = Uri.tryParse(href);
    if (uri != null && uri.hasScheme) return href;
    if (href.startsWith("//")) return "https:$href";
    if (href.startsWith("/")) return "$domain$href";
    return path.url.join(domain, href);
  }

  String _clean(String? value) {
    return (value ?? "").replaceAll(RegExp(r"\s+"), " ").trim();
  }

  void _ensureSearchPageUsable(String html, String sourceName) {
    final lower = html.toLowerCase();
    if (lower.contains("cloudflare") ||
        lower.contains("cf-wrapper") ||
        lower.contains("just a moment") ||
        lower.contains("sorry, you have been blocked") ||
        lower.contains("enable javascript and cookies")) {
      throw StateError(
        "$sourceName 搜索被源站安全验证拦截，请稍后重试，或直接粘贴小说详情页链接读取目录。",
      );
    }
  }

  String _cleanError(Object error) {
    if (error is StateError) return error.message;
    if (error is FormatException) return error.message;
    return error.toString();
  }
}

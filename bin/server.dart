import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ln_packer_web/web/download_headers.dart';
import 'package:ln_packer_web/web/job_manager.dart';
import 'package:ln_packer_web/web/novel_search.dart';
import 'package:path/path.dart' as path;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_static/shelf_static.dart';

Future<void> main(List<String> args) async {
  final env = Platform.environment;
  final host = env["PACKER_HOST"] ?? "0.0.0.0";
  final port = _envInt(env["PACKER_PORT"], 8080);
  final dataDir = Directory(env["PACKER_DATA_DIR"] ?? "data");
  final publicDir = env["PACKER_PUBLIC_DIR"] ?? path.join("web", "dist");
  final maxConcurrent = _envInt(env["PACKER_MAX_CONCURRENT"], 1);
  final sourceRateMode = (env["PACKER_SOURCE_RATE_MODE"] ?? "stable").trim();
  final defaultChapterConcurrency = sourceRateMode == "fast" ? 10 : 6;
  final defaultImageConcurrency = sourceRateMode == "fast" ? 12 : 8;
  final chapterConcurrency = _envInt(
    env["PACKER_CHAPTER_CONCURRENCY"],
    defaultChapterConcurrency,
  );
  final imageConcurrency = _envInt(
    env["PACKER_IMAGE_CONCURRENCY"],
    defaultImageConcurrency,
  );
  final fileTtlHours = _envInt(env["PACKER_FILE_TTL_HOURS"], 24);
  final accessToken = env["PACKER_ACCESS_TOKEN"];

  final manager = PackJobManager(
    dataDirectory: dataDir,
    maxConcurrent: maxConcurrent < 1 ? 1 : maxConcurrent,
    chapterConcurrency: chapterConcurrency < 1 ? 1 : chapterConcurrency,
    imageConcurrency: imageConcurrency < 1 ? 1 : imageConcurrency,
    sourceRateMode: sourceRateMode == "fast" ? "fast" : "stable",
    fileTtl: Duration(hours: fileTtlHours < 1 ? 24 : fileTtlHours),
  );
  final searchService = NovelSearchService();

  Timer.periodic(
    const Duration(hours: 1),
    (_) => manager.cleanupExpiredFiles(),
  );

  final router = _buildRouter(manager, searchService);
  final staticHandler = _buildStaticHandler(publicDir);
  final handler = Pipeline()
      .addMiddleware(logRequests())
      .addMiddleware(_corsMiddleware())
      .addMiddleware(_authMiddleware(accessToken))
      .addHandler((request) async {
    final response = await router.call(request);
    if (request.url.path.startsWith("api/") || response.statusCode != 404) {
      return response;
    }
    return staticHandler(request);
  });

  final server = await shelf_io.serve(handler, host, port);
  print("bili-novel-UI-Packer 服务已启动: http://${server.address.host}:$port");
  print("数据目录: ${dataDir.absolute.path}");
  print("静态资源目录: ${Directory(publicDir).absolute.path}");
}

Router _buildRouter(PackJobManager manager, NovelSearchService searchService) {
  final router = Router();

  router.get("/api/health", (Request request) {
    return _jsonResponse({
      "ok": true,
      "time": DateTime.now().toUtc().toIso8601String(),
      "config": manager.runtimeConfig,
    });
  });

  router.post("/api/novels/preview", (Request request) async {
    try {
      final body = await _readJson(request);
      final url = body["url"];
      if (url is! String || url.trim().isEmpty) {
        return _jsonResponse({"error": "url 不能为空"}, status: 400);
      }
      final preview = await manager.preview(url);
      return _jsonResponse(preview);
    } on FormatException catch (error) {
      return _jsonResponse({"error": error.message}, status: 400);
    } on StateError catch (error) {
      final cloudflare = error.message.contains("安全验证");
      return _jsonResponse({
        "error": error.message,
        if (cloudflare) "code": "cloudflare_verification_required",
      }, status: 502);
    } catch (error) {
      return _jsonResponse({"error": error.toString()}, status: 500);
    }
  });

  router.get("/api/novels/search", (Request request) async {
    try {
      final query = request.url.queryParameters["query"] ?? "";
      final source = request.url.queryParameters["source"] ?? "all";
      final page =
          int.tryParse(request.url.queryParameters["page"] ?? "1") ?? 1;
      final results = await searchService.search(
        query: query,
        source: source,
        page: page,
      );
      return _jsonResponse({
        "query": query,
        "source": source,
        "page": page < 1 ? 1 : page,
        "results": [for (final item in results) item.toJson()],
      });
    } on FormatException catch (error) {
      return _jsonResponse({"error": error.message}, status: 400);
    } on StateError catch (error) {
      final cloudflare = error.message.contains("安全验证");
      return _jsonResponse({
        "error": error.message,
        if (cloudflare) "code": "cloudflare_verification_required",
      }, status: 502);
    } catch (error) {
      return _jsonResponse({"error": error.toString()}, status: 500);
    }
  });

  router.get("/api/jobs", (Request request) {
    manager.cleanupExpiredFiles();
    return _jsonResponse({
      "jobs": [for (final job in manager.listJobs()) job.toJson()],
    });
  });

  router.post("/api/jobs", (Request request) async {
    try {
      final jobRequest = CreateJobRequest.fromJson(await _readJson(request));
      final job = manager.createJob(jobRequest);
      return _jsonResponse(job.toJson(), status: 202);
    } on FormatException catch (error) {
      return _jsonResponse({"error": error.message}, status: 400);
    } catch (error) {
      return _jsonResponse({"error": error.toString()}, status: 500);
    }
  });

  router.post("/api/jobs/<id>/cancel", (Request request, String id) {
    final job = manager.cancelJob(id);
    if (job == null) {
      return _jsonResponse({"error": "任务不存在"}, status: 404);
    }
    return _jsonResponse(job.toJson());
  });

  router.delete("/api/jobs/<id>", (Request request, String id) {
    final result = manager.deleteJob(id);
    if (result.running) {
      return _jsonResponse({
        "error": "任务正在运行，请先取消后再删除。",
        "code": "job_running",
      }, status: 409);
    }
    return _jsonResponse({
      "deleted": true,
      "id": id,
      "missing": result.missing,
    });
  });

  router.get("/api/jobs/<id>", (Request request, String id) {
    final job = manager.getJob(id);
    if (job == null) {
      return _jsonResponse({"error": "任务不存在"}, status: 404);
    }
    return _jsonResponse(job.toJson());
  });

  router.get("/api/jobs/<id>/events", (Request request, String id) {
    final job = manager.getJob(id);
    if (job == null) {
      return _jsonResponse({"error": "任务不存在"}, status: 404);
    }
    final events = manager.subscribe(id).map((event) {
      final eventName = event["event"] as String? ?? "job";
      final data = event["data"] ?? event;
      return "event: $eventName\ndata: ${jsonEncode(data)}\n\n";
    });
    return Response.ok(
      utf8.encoder.bind(events),
      headers: {
        "content-type": "text/event-stream; charset=utf-8",
        "cache-control": "no-cache, no-transform",
        "connection": "keep-alive",
        "x-accel-buffering": "no",
      },
    );
  });

  router.head(
    "/api/jobs/<id>/files/<fileId>",
    (Request request, String id, String fileId) =>
        _downloadFileResponse(manager, id, fileId, includeBody: false),
  );

  router.get(
    "/api/jobs/<id>/files/<fileId>",
    (Request request, String id, String fileId) =>
        _downloadFileResponse(manager, id, fileId, includeBody: true),
  );

  return router;
}

Handler _buildStaticHandler(String publicDir) {
  if (!Directory(publicDir).existsSync()) {
    return (Request request) => Response.notFound(
          "前端资源不存在，请先构建 web/dist 或设置 PACKER_PUBLIC_DIR。",
        );
  }
  return createStaticHandler(publicDir, defaultDocument: "index.html");
}

Middleware _authMiddleware(String? accessToken) {
  final token = accessToken?.trim();
  if (token == null || token.isEmpty) {
    return (Handler innerHandler) => innerHandler;
  }

  return (Handler innerHandler) {
    return (Request request) async {
      if (!request.url.path.startsWith("api/") ||
          request.url.path == "api/health") {
        return innerHandler(request);
      }
      if (_authorized(request, token)) {
        return innerHandler(request);
      }
      return _jsonResponse({"error": "访问令牌无效"}, status: 403);
    };
  };
}

bool _authorized(Request request, String token) {
  final authHeader = request.headers["authorization"];
  final headerToken = request.headers["x-packer-token"];
  final queryToken = request.url.queryParameters["token"] ??
      request.url.queryParameters["access_token"];
  return authHeader == "Bearer $token" ||
      headerToken == token ||
      queryToken == token;
}

Middleware _corsMiddleware() {
  const headers = {
    "access-control-allow-origin": "*",
    "access-control-allow-methods": "GET,HEAD,POST,DELETE,OPTIONS",
    "access-control-allow-headers": "content-type,authorization,x-packer-token",
  };

  return (Handler innerHandler) {
    return (Request request) async {
      if (request.method == "OPTIONS") {
        return Response.ok("", headers: headers);
      }
      final response = await innerHandler(request);
      return response.change(headers: {
        ...response.headers,
        ...headers,
      });
    };
  };
}

Response _downloadFileResponse(
  PackJobManager manager,
  String id,
  String fileId, {
  required bool includeBody,
}) {
  final jobFile = manager.getFile(id, fileId);
  if (jobFile == null) {
    return _jsonResponse({"error": "文件不存在"}, status: 404);
  }
  if (jobFile.expired) {
    return _jsonResponse({"error": "文件已过期"}, status: 410);
  }
  final file = File(jobFile.path);
  if (!file.existsSync()) {
    return _jsonResponse({"error": "文件已被清理"}, status: 404);
  }
  return Response.ok(
    includeBody ? file.openRead() : null,
    headers: {
      "content-type": "application/epub+zip",
      "content-length": file.lengthSync().toString(),
      "content-disposition": contentDispositionForDownload(jobFile.name),
    },
  );
}

Future<Map<String, Object?>> _readJson(Request request) async {
  final text = await request.readAsString();
  if (text.trim().isEmpty) return <String, Object?>{};
  final value = jsonDecode(text);
  if (value is Map<String, Object?>) return value;
  if (value is Map) return Map<String, Object?>.from(value);
  throw const FormatException("请求体必须是 JSON 对象");
}

Response _jsonResponse(Object? body, {int status = 200}) {
  return Response(
    status,
    body: jsonEncode(body),
    headers: {"content-type": "application/json; charset=utf-8"},
  );
}

int _envInt(String? value, int fallback) {
  if (value == null) return fallback;
  return int.tryParse(value) ?? fallback;
}

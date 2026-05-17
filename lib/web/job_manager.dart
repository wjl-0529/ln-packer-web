import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:ln_packer_web/light_novel/base/light_novel_model.dart';
import 'package:ln_packer_web/novel_packer.dart';
import 'package:ln_packer_web/pack_run_context.dart';
import 'package:ln_packer_web/pack_argument.dart';
import 'package:ln_packer_web/util/cancellation.dart';
import 'package:ln_packer_web/web/serializers.dart';
import 'package:ln_packer_web/web/volume_selection.dart';
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';

DateTime _nowUtc() => DateTime.now().toUtc();

double _completedPercent(int completed, int total) {
  if (total <= 0) return 0;
  return (completed / total * 100).clamp(0, 100).toDouble();
}

class CreateJobRequest {
  final String url;
  final List<int>? volumeIndexes;
  final String? volumeRange;
  final bool combineVolume;
  final bool addChapterTitle;

  CreateJobRequest({
    required this.url,
    required this.volumeIndexes,
    required this.volumeRange,
    required this.combineVolume,
    required this.addChapterTitle,
  });

  factory CreateJobRequest.fromJson(Map<String, Object?> json) {
    final url = json["url"];
    if (url is! String || url.trim().isEmpty) {
      throw FormatException("url 不能为空");
    }

    List<int>? volumeIndexes;
    final rawIndexes = json["volumeIndexes"];
    if (rawIndexes is List) {
      volumeIndexes = [
        for (final value in rawIndexes)
          if (value is num) value.toInt(),
      ];
    }

    return CreateJobRequest(
      url: url.trim(),
      volumeIndexes: volumeIndexes,
      volumeRange: json["volumeRange"] is String
          ? (json["volumeRange"] as String).trim()
          : null,
      combineVolume: json["combineVolume"] == true,
      addChapterTitle: json["addChapterTitle"] == true,
    );
  }
}

class LogEntry {
  final DateTime time;
  final String level;
  final String message;

  LogEntry({
    required this.time,
    required this.level,
    required this.message,
  });

  factory LogEntry.info(String message) {
    return LogEntry(time: _nowUtc(), level: "INFO", message: message);
  }

  factory LogEntry.error(String message) {
    return LogEntry(time: _nowUtc(), level: "ERROR", message: message);
  }

  factory LogEntry.fromJson(Object? value, DateTime fallbackTime) {
    if (value is String) {
      return LogEntry(
        time: fallbackTime.toUtc(),
        level: "INFO",
        message: value,
      );
    }
    if (value is Map) {
      final map = Map<String, Object?>.from(value);
      return LogEntry(
        time: DateTime.tryParse(map["time"] as String? ?? "")?.toUtc() ??
            fallbackTime.toUtc(),
        level: map["level"] as String? ?? "INFO",
        message: map["message"] as String? ?? "",
      );
    }
    return LogEntry(time: fallbackTime.toUtc(), level: "INFO", message: "");
  }

  Map<String, Object?> toJson() {
    return {
      "time": time.toUtc().toIso8601String(),
      "level": level,
      "message": message,
    };
  }
}

class JobFile {
  final String id;
  final String name;
  final String path;
  final int sizeBytes;
  final DateTime createdAt;
  final DateTime expiresAt;

  JobFile({
    required this.id,
    required this.name,
    required this.path,
    required this.sizeBytes,
    required this.createdAt,
    required this.expiresAt,
  });

  bool get expired => _nowUtc().isAfter(expiresAt);

  Map<String, Object?> toJson(String jobId) {
    return {
      "id": id,
      "name": name,
      "sizeBytes": sizeBytes,
      "createdAt": createdAt.toUtc().toIso8601String(),
      "expiresAt": expiresAt.toUtc().toIso8601String(),
      "expired": expired,
      "downloadUrl": expired ? null : "/api/jobs/$jobId/files/$id",
    };
  }

  factory JobFile.fromJson(Map<String, Object?> json) {
    return JobFile(
      id: json["id"] as String,
      name: json["name"] as String,
      path: json["path"] as String,
      sizeBytes: (json["sizeBytes"] as num).toInt(),
      createdAt: DateTime.parse(json["createdAt"] as String).toUtc(),
      expiresAt: DateTime.parse(json["expiresAt"] as String).toUtc(),
    );
  }

  Map<String, Object?> toManifestJson() {
    return {
      "id": id,
      "name": name,
      "path": path,
      "sizeBytes": sizeBytes,
      "createdAt": createdAt.toUtc().toIso8601String(),
      "expiresAt": expiresAt.toUtc().toIso8601String(),
    };
  }
}

class PackJob {
  final String id;
  final String url;
  final DateTime createdAt;
  final List<LogEntry> logs = [];
  final List<JobFile> files = [];
  final StreamController<Map<String, Object?>> _events =
      StreamController<Map<String, Object?>>.broadcast(sync: true);
  DateTime? _lastProgressEventAt;

  String status = "queued";
  String message = "等待开始";
  String? error;
  String phase = "queued";
  String? currentVolume;
  String? currentChapter;
  int activeChapterCount = 0;
  int completed = 0;
  int total = 0;
  double percent = 0;
  DateTime updatedAt;
  DateTime? startedAt;
  DateTime? finishedAt;
  bool cancelRequested = false;
  Map<String, Object?>? novel;
  Map<String, Object?>? catalog;

  PackJob({
    required this.id,
    required this.url,
    required this.createdAt,
  }) : updatedAt = createdAt.toUtc();

  factory PackJob.fromJson(Map<String, Object?> json) {
    final job = PackJob(
      id: json["id"] as String,
      url: json["url"] as String,
      createdAt: DateTime.parse(json["createdAt"] as String).toUtc(),
    );
    job.status = json["status"] as String? ?? "completed";
    job.message = json["message"] as String? ?? "已从本地记录恢复";
    job.error = json["error"] as String?;
    job.phase = json["phase"] as String? ?? job.status;
    job.currentVolume = json["currentVolume"] as String?;
    job.currentChapter = json["currentChapter"] as String?;
    job.activeChapterCount = (json["activeChapterCount"] as num?)?.toInt() ?? 0;
    job.completed = (json["completed"] as num?)?.toInt() ?? 0;
    job.total = (json["total"] as num?)?.toInt() ?? 0;
    job.percent = (json["percent"] as num?)?.toDouble() ??
        _completedPercent(job.completed, job.total);
    job.updatedAt =
        DateTime.tryParse(json["updatedAt"] as String? ?? "") ?? job.createdAt;
    job.updatedAt = job.updatedAt.toUtc();
    job.startedAt =
        DateTime.tryParse(json["startedAt"] as String? ?? "")?.toUtc();
    job.finishedAt =
        DateTime.tryParse(json["finishedAt"] as String? ?? "")?.toUtc();
    final novel = json["novel"];
    if (novel is Map) {
      job.novel = Map<String, Object?>.from(novel);
    }
    final catalog = json["catalog"];
    if (catalog is Map) {
      job.catalog = Map<String, Object?>.from(catalog);
    }
    final logs = json["logs"];
    if (logs is List) {
      job.logs.addAll(logs.map((log) => LogEntry.fromJson(log, job.updatedAt)));
    }
    final files = json["files"];
    if (files is List) {
      for (final file in files) {
        if (file is Map) {
          job.files.add(JobFile.fromJson(Map<String, Object?>.from(file)));
        }
      }
    }
    if (job.status == "queued" || job.status == "running") {
      job.status = "failed";
      job.message = "服务重启，未完成任务已停止";
      job.error ??= "任务运行期间服务被重启，请重新提交打包。";
      job.phase = "failed";
      job.finishedAt ??= job.updatedAt;
    }
    return job;
  }

  bool get terminal =>
      status == "completed" || status == "failed" || status == "canceled";

  Stream<Map<String, Object?>> get events => _events.stream;

  void addLog(String message) {
    logs.add(LogEntry.info(message));
    if (logs.length > 200) {
      logs.removeRange(0, logs.length - 200);
    }
    touch(message: message);
  }

  void addErrorLog(String message) {
    logs.add(LogEntry.error(message));
    if (logs.length > 200) {
      logs.removeRange(0, logs.length - 200);
    }
    touch(message: message);
  }

  void touch({
    String? status,
    String? message,
    String? error,
    String? phase,
    String? currentVolume,
    String? currentChapter,
    int? activeChapterCount,
    int? completed,
    int? total,
    double? percent,
    DateTime? startedAt,
    DateTime? finishedAt,
    bool forceEvent = false,
  }) {
    if (status != null) this.status = status;
    if (message != null) this.message = message;
    if (error != null) this.error = error;
    if (phase != null) this.phase = phase;
    if (currentVolume != null) this.currentVolume = currentVolume;
    if (currentChapter != null) this.currentChapter = currentChapter;
    if (activeChapterCount != null) {
      this.activeChapterCount = activeChapterCount;
    }
    if (completed != null) this.completed = completed;
    if (total != null) this.total = total;
    if (percent != null) {
      this.percent = percent.clamp(0, 100).toDouble();
    } else if (completed != null || total != null) {
      this.percent = _completedPercent(this.completed, this.total);
    }
    if (startedAt != null) this.startedAt = startedAt.toUtc();
    if (finishedAt != null) this.finishedAt = finishedAt.toUtc();
    updatedAt = _nowUtc();
    if (terminal) {
      publishJob();
    } else {
      publishProgress(force: forceEvent);
    }
  }

  void publishJob() {
    if (!_events.isClosed) {
      _events.add({
        "event": "job",
        "data": toJson(),
      });
    }
  }

  void publishProgress({bool force = false}) {
    if (_events.isClosed) return;
    final now = _nowUtc();
    if (!force &&
        _lastProgressEventAt != null &&
        now.difference(_lastProgressEventAt!) <
            const Duration(milliseconds: 250)) {
      return;
    }
    _lastProgressEventAt = now;
    _events.add({
      "event": "progress",
      "data": toProgressJson(),
    });
  }

  void closeEvents() {
    if (!_events.isClosed) {
      _events.close();
    }
  }

  Map<String, Object?> toJson() {
    return {
      "id": id,
      "url": url,
      "status": status,
      "message": message,
      "error": error,
      "phase": phase,
      "currentVolume": currentVolume,
      "currentChapter": currentChapter,
      "activeChapterCount": activeChapterCount,
      "completed": completed,
      "total": total,
      "percent": percent,
      "createdAt": createdAt.toUtc().toIso8601String(),
      "updatedAt": updatedAt.toUtc().toIso8601String(),
      "startedAt": startedAt?.toUtc().toIso8601String(),
      "finishedAt": finishedAt?.toUtc().toIso8601String(),
      "novel": novel,
      "catalog": catalog,
      "logs": [for (final log in logs.takeLast(80)) log.toJson()],
      "files": [for (final file in files) file.toJson(id)],
    };
  }

  Map<String, Object?> toProgressJson() {
    return {
      "id": id,
      "status": status,
      "message": message,
      "error": error,
      "phase": phase,
      "currentVolume": currentVolume,
      "currentChapter": currentChapter,
      "activeChapterCount": activeChapterCount,
      "completed": completed,
      "total": total,
      "percent": percent,
      "updatedAt": updatedAt.toUtc().toIso8601String(),
      "startedAt": startedAt?.toUtc().toIso8601String(),
      "finishedAt": finishedAt?.toUtc().toIso8601String(),
      "latestLog": logs.isEmpty ? null : logs.last.toJson(),
    };
  }

  Map<String, Object?> toManifestJson() {
    return {
      "id": id,
      "url": url,
      "status": status,
      "message": message,
      "error": error,
      "phase": phase,
      "currentVolume": currentVolume,
      "currentChapter": currentChapter,
      "activeChapterCount": activeChapterCount,
      "completed": completed,
      "total": total,
      "percent": percent,
      "createdAt": createdAt.toUtc().toIso8601String(),
      "updatedAt": updatedAt.toUtc().toIso8601String(),
      "startedAt": startedAt?.toUtc().toIso8601String(),
      "finishedAt": finishedAt?.toUtc().toIso8601String(),
      "novel": novel,
      "catalog": catalog,
      "logs": [for (final log in logs.takeLast(80)) log.toJson()],
      "files": [for (final file in files) file.toManifestJson()],
    };
  }
}

class DeleteJobResult {
  final String status;
  final PackJob? job;
  final bool missing;

  const DeleteJobResult._(
    this.status, {
    this.job,
    this.missing = false,
  });

  bool get deleted => status == "deleted";
  bool get running => status == "running";

  factory DeleteJobResult.deleted(PackJob job) =>
      DeleteJobResult._("deleted", job: job);

  factory DeleteJobResult.missing() =>
      const DeleteJobResult._("deleted", missing: true);

  factory DeleteJobResult.running(PackJob job) =>
      DeleteJobResult._("running", job: job);
}

class PackJobManager {
  final Directory dataDirectory;
  final int maxConcurrent;
  final int chapterConcurrency;
  final int imageConcurrency;
  final String sourceRateMode;
  final Duration fileTtl;
  final Uuid _uuid = Uuid();
  final Map<String, PackJob> _jobs = {};
  final Map<String, PackRunContext> _contexts = {};
  final Queue<String> _queue = Queue<String>();
  int _running = 0;

  File get _manifestFile => File(path.join(dataDirectory.path, "jobs.json"));

  PackJobManager({
    required this.dataDirectory,
    required this.maxConcurrent,
    this.chapterConcurrency = 6,
    this.imageConcurrency = 8,
    this.sourceRateMode = "stable",
    required this.fileTtl,
  }) {
    dataDirectory.createSync(recursive: true);
    Directory(path.join(dataDirectory.path, "jobs"))
        .createSync(recursive: true);
    _loadManifest();
  }

  Future<Map<String, Object?>> preview(String url) async {
    final packer = NovelPacker.fromUrl(url.trim());
    await packer.init();
    return {
      "novel": novelToJson(packer.novel),
      "catalog": catalogToJson(packer.catalog),
      "source": {
        "name": packer.lightNovelSource.name,
        "url": packer.lightNovelSource.sourceUrl,
      },
    };
  }

  PackJob createJob(CreateJobRequest request) {
    cleanupExpiredFiles();
    final id = _uuid.v4();
    final job = PackJob(id: id, url: request.url, createdAt: _nowUtc());
    _jobs[id] = job;
    _queue.add(id);
    job.touch(status: "queued", message: "任务已加入队列");
    _saveManifest();
    _pump(requests: {id: request});
    return job;
  }

  PackJob? getJob(String id) => _jobs[id];

  Map<String, Object?> get runtimeConfig => {
        "maxConcurrent": maxConcurrent,
        "chapterConcurrency": chapterConcurrency,
        "imageConcurrency": imageConcurrency,
        "sourceRateMode": sourceRateMode,
        "fileTtlHours": fileTtl.inHours,
      };

  List<PackJob> listJobs() {
    final jobs = _jobs.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return jobs;
  }

  JobFile? getFile(String jobId, String fileId) {
    final job = _jobs[jobId];
    if (job == null) return null;
    for (final file in job.files) {
      if (file.id == fileId) return file;
    }
    return null;
  }

  PackJob? cancelJob(String id) {
    final job = _jobs[id];
    if (job == null) return null;
    if (job.terminal) return job;

    job.cancelRequested = true;
    _contexts[id]?.cancel();
    _requests.remove(id);
    _queue.remove(id);

    if (job.status == "queued") {
      _cleanupJobOutput(job.id);
      job.touch(
        status: "canceled",
        phase: "canceled",
        message: "任务已取消",
        activeChapterCount: 0,
        finishedAt: _nowUtc(),
        forceEvent: true,
      );
      _saveManifest();
      scheduleMicrotask(job.closeEvents);
      return job;
    }

    job.touch(
      phase: "canceling",
      message: "正在取消任务，已开始的请求会尽快停止",
      forceEvent: true,
    );
    _saveManifest();
    return job;
  }

  DeleteJobResult deleteJob(String id) {
    final job = _jobs[id];
    if (job == null) {
      _cleanupJobOutput(id);
      _saveManifest();
      return DeleteJobResult.missing();
    }
    if (job.status == "running") {
      return DeleteJobResult.running(job);
    }

    if (job.status == "queued") {
      cancelJob(id);
    }
    _requests.remove(id);
    _queue.remove(id);
    _contexts.remove(id)?.cancel();
    _cleanupJobOutput(id);
    _jobs.remove(id);
    _saveManifest();
    scheduleMicrotask(job.closeEvents);
    return DeleteJobResult.deleted(job);
  }

  Stream<Map<String, Object?>> subscribe(String jobId) {
    final job = _jobs[jobId];
    if (job == null) {
      throw StateError("任务不存在");
    }

    late StreamController<Map<String, Object?>> controller;
    StreamSubscription<Map<String, Object?>>? jobSubscription;
    Timer? heartbeatTimer;

    void closeController() {
      heartbeatTimer?.cancel();
      heartbeatTimer = null;
      if (!controller.isClosed) {
        controller.close();
      }
    }

    controller = StreamController<Map<String, Object?>>(
      onListen: () {
        controller.add({
          "event": "job",
          "data": job.toJson(),
        });
        if (job.terminal) {
          scheduleMicrotask(closeController);
          return;
        }

        jobSubscription = job.events.listen(
          (event) {
            if (!controller.isClosed) {
              controller.add(event);
            }
          },
          onDone: closeController,
        );
        heartbeatTimer = Timer.periodic(const Duration(seconds: 10), (_) {
          if (controller.isClosed) return;
          if (job.terminal) {
            controller.add({
              "event": "job",
              "data": job.toJson(),
            });
            closeController();
            return;
          }
          controller.add({
            "event": "progress",
            "data": job.toProgressJson(),
          });
        });
      },
      onCancel: () async {
        heartbeatTimer?.cancel();
        await jobSubscription?.cancel();
      },
    );
    return controller.stream;
  }

  final Map<String, CreateJobRequest> _requests = {};

  void _pump({Map<String, CreateJobRequest>? requests}) {
    if (requests != null) {
      _requests.addAll(requests);
    }
    while (_running < maxConcurrent && _queue.isNotEmpty) {
      final id = _queue.removeFirst();
      final job = _jobs[id];
      final request = _requests.remove(id);
      if (job == null || request == null) continue;
      _running++;
      unawaited(_run(job, request).whenComplete(() {
        _running--;
        _pump();
      }));
    }
  }

  Future<void> _run(PackJob job, CreateJobRequest request) async {
    final runContext = PackRunContext();
    _contexts[job.id] = runContext;
    try {
      if (job.cancelRequested) {
        throw const PackCanceledException();
      }
      job.touch(
        status: "running",
        phase: "metadata",
        message: "正在读取小说信息",
        startedAt: _nowUtc(),
        forceEvent: true,
      );
      final packer = NovelPacker.fromUrl(request.url, runContext: runContext);
      await packer.init(
        novelCallback: (novel) {
          if (job.cancelRequested) {
            throw const PackCanceledException();
          }
          job.novel = novelToJson(novel);
          job.touch(phase: "metadata", message: "已读取小说信息");
          job.publishJob();
          _saveManifest();
        },
        catalogCallback: (catalog) {
          if (job.cancelRequested) {
            throw const PackCanceledException();
          }
          job.catalog = catalogToJson(catalog);
          job.touch(phase: "catalog", message: "已读取分卷目录");
          job.publishJob();
          _saveManifest();
        },
      );

      final volumes = _selectVolumes(request, packer.catalog);
      if (volumes.isEmpty) {
        throw FormatException("至少需要选择一个分卷");
      }

      final outputDirectory = Directory(path.join(
        dataDirectory.path,
        "jobs",
        job.id,
      ));
      outputDirectory.createSync(recursive: true);

      final files = await packer.pack(
        PackArgument.all(
          addChapterTitle: request.addChapterTitle,
          combineVolume: request.combineVolume,
          packVolumes: volumes,
        ),
        outputDirectory: outputDirectory.path,
        chapterConcurrency: chapterConcurrency,
        imageConcurrency: imageConcurrency,
        isCanceled: () => job.cancelRequested || runContext.isCanceled,
        onLog: job.addLog,
        onProgress: (progress) {
          job.touch(
            status: "running",
            phase: progress.phase,
            message: progress.message,
            currentVolume: progress.volumeName,
            currentChapter: progress.chapterName,
            activeChapterCount: progress.activeChapterCount,
            completed: progress.completed,
            total: progress.total,
            percent: progress.percent,
          );
        },
      );

      if (job.cancelRequested) {
        throw const PackCanceledException();
      }

      final createdAt = _nowUtc();
      final expiresAt = createdAt.add(fileTtl);
      for (final file in files) {
        if (!file.existsSync()) continue;
        job.files.add(JobFile(
          id: _uuid.v4(),
          name: path.basename(file.path),
          path: file.path,
          sizeBytes: file.lengthSync(),
          createdAt: createdAt,
          expiresAt: expiresAt,
        ));
      }
      job.touch(
        status: "completed",
        phase: "completed",
        message: "打包完成，可下载 ${job.files.length} 个 EPUB 文件",
        completed: job.total,
        percent: 100,
        activeChapterCount: 0,
        finishedAt: _nowUtc(),
        forceEvent: true,
      );
      _saveManifest();
    } on PackCanceledException {
      _cleanupJobOutput(job.id);
      job.touch(
        status: "canceled",
        phase: "canceled",
        message: "任务已取消",
        activeChapterCount: 0,
        finishedAt: _nowUtc(),
        forceEvent: true,
      );
      _saveManifest();
    } on CancellationException {
      _cleanupJobOutput(job.id);
      job.touch(
        status: "canceled",
        phase: "canceled",
        message: "任务已取消",
        activeChapterCount: 0,
        finishedAt: _nowUtc(),
        forceEvent: true,
      );
      _saveManifest();
    } catch (error, stackTrace) {
      job.addErrorLog(stackTrace.toString());
      job.touch(
        status: "failed",
        phase: "failed",
        message: "任务失败",
        error: error.toString(),
        activeChapterCount: 0,
        finishedAt: _nowUtc(),
        forceEvent: true,
      );
      _saveManifest();
    } finally {
      _contexts.remove(job.id);
      runContext.dispose();
      scheduleMicrotask(job.closeEvents);
    }
  }

  List<Volume> _selectVolumes(CreateJobRequest request, Catalog catalog) {
    List<int> indexes;
    if (request.volumeRange != null && request.volumeRange!.isNotEmpty) {
      indexes =
          parseVolumeSelection(request.volumeRange!, catalog.volumes.length);
    } else if (request.volumeIndexes != null &&
        request.volumeIndexes!.isNotEmpty) {
      indexes = request.volumeIndexes!;
    } else {
      indexes = List<int>.generate(catalog.volumes.length, (index) => index);
    }

    final selected = <Volume>[];
    for (final index in indexes.toSet().toList()..sort()) {
      if (index < 0 || index >= catalog.volumes.length) {
        throw RangeError.range(
            index, 0, catalog.volumes.length - 1, "volumeIndex");
      }
      selected.add(catalog.volumes[index]);
    }
    return selected;
  }

  void cleanupExpiredFiles() {
    final now = _nowUtc();
    for (final job in _jobs.values) {
      for (final file in job.files) {
        if (now.isAfter(file.expiresAt)) {
          final target = File(file.path);
          if (target.existsSync()) {
            target.deleteSync();
          }
        }
      }
    }
    _saveManifest();
  }

  void _cleanupJobOutput(String jobId) {
    final jobsRoot = Directory(path.join(dataDirectory.path, "jobs"));
    final target = Directory(path.join(jobsRoot.path, jobId));
    final rootPath = path.normalize(jobsRoot.absolute.path);
    final targetPath = path.normalize(target.absolute.path);
    if (!path.isWithin(rootPath, targetPath) && rootPath != targetPath) {
      return;
    }
    if (target.existsSync()) {
      target.deleteSync(recursive: true);
    }
    final job = _jobs[jobId];
    job?.files.clear();
  }

  void _loadManifest() {
    final manifest = _manifestFile;
    if (!manifest.existsSync()) return;
    try {
      final decoded = jsonDecode(manifest.readAsStringSync());
      final jobs = decoded is Map ? decoded["jobs"] : decoded;
      if (jobs is! List) return;
      for (final item in jobs) {
        if (item is! Map) continue;
        final job = PackJob.fromJson(Map<String, Object?>.from(item));
        _jobs[job.id] = job;
      }
      cleanupExpiredFiles();
    } catch (_) {
      final backupPath =
          "${manifest.path}.invalid.${_nowUtc().millisecondsSinceEpoch}";
      manifest.renameSync(backupPath);
    }
  }

  void _saveManifest() {
    final manifest = _manifestFile;
    manifest.parent.createSync(recursive: true);
    final jobs =
        listJobs().take(100).map((job) => job.toManifestJson()).toList();
    manifest.writeAsStringSync(
      const JsonEncoder.withIndent("  ").convert({"jobs": jobs}),
    );
  }
}

extension _TakeLast<T> on Iterable<T> {
  Iterable<T> takeLast(int count) {
    if (count <= 0) return <T>[];
    final list = toList(growable: false);
    if (list.length <= count) return list;
    return list.skip(list.length - count);
  }
}

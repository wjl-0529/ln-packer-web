import 'dart:io';

import 'package:ln_packer_web/web/job_manager.dart';
import 'package:test/test.dart';

void main() {
  test("restored unfinished jobs are marked failed", () {
    final now = DateTime.now();
    final job = PackJob.fromJson({
      "id": "job-1",
      "url": "https://www.bilinovel.com/novel/1.html",
      "status": "running",
      "message": "正在打包",
      "completed": 2,
      "total": 10,
      "createdAt": now.toIso8601String(),
      "updatedAt": now.toIso8601String(),
      "logs": ["started"],
      "files": <Object?>[],
    });

    expect(job.status, "failed");
    expect(job.message, "服务重启，未完成任务已停止");
    expect(job.error, contains("重新提交"));
  });

  test("job files survive manifest round trip", () {
    final now = DateTime.now();
    final file = JobFile(
      id: "file-1",
      name: "中文.epub",
      path: "/tmp/中文.epub",
      sizeBytes: 42,
      createdAt: now,
      expiresAt: now.add(const Duration(hours: 1)),
    );
    final restored = JobFile.fromJson(file.toManifestJson());

    expect(restored.id, file.id);
    expect(restored.name, file.name);
    expect(restored.sizeBytes, file.sizeBytes);
  });

  test("old string logs are restored as structured logs", () {
    final now = DateTime.now().toUtc();
    final job = PackJob.fromJson({
      "id": "job-2",
      "url": "https://www.bilinovel.com/novel/1.html",
      "status": "completed",
      "message": "done",
      "createdAt": now.toIso8601String(),
      "updatedAt": now.toIso8601String(),
      "logs": ["旧日志"],
      "files": <Object?>[],
    });

    expect(job.logs.single.message, "旧日志");
    expect(job.logs.single.level, "INFO");
    expect(job.logs.single.time.isUtc, isTrue);
  });

  test("queued jobs can be canceled without starting packer", () {
    final dir = Directory.systemTemp.createTempSync("packer_cancel_test_");
    try {
      final manager = PackJobManager(
        dataDirectory: dir,
        maxConcurrent: 0,
        fileTtl: const Duration(hours: 1),
      );
      final job = manager.createJob(CreateJobRequest(
        url: "https://example.invalid/novel/1.html",
        volumeIndexes: const [0],
        volumeRange: null,
        combineVolume: true,
        addChapterTitle: true,
      ));

      final canceled = manager.cancelJob(job.id);

      expect(canceled, isNotNull);
      expect(canceled!.status, "canceled");
      expect(canceled.phase, "canceled");
      expect(canceled.finishedAt, isNotNull);
    } finally {
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    }
  });

  test("queued jobs can be deleted with their output directory", () {
    final dir = Directory.systemTemp.createTempSync("packer_delete_test_");
    try {
      final manager = PackJobManager(
        dataDirectory: dir,
        maxConcurrent: 0,
        fileTtl: const Duration(hours: 1),
      );
      final job = manager.createJob(CreateJobRequest(
        url: "https://example.invalid/novel/1.html",
        volumeIndexes: const [0],
        volumeRange: null,
        combineVolume: true,
        addChapterTitle: true,
      ));
      final output = Directory("${dir.path}/jobs/${job.id}")
        ..createSync(recursive: true);
      File("${output.path}/partial.epub").writeAsStringSync("partial");

      final result = manager.deleteJob(job.id);

      expect(result.deleted, isTrue);
      expect(manager.getJob(job.id), isNull);
      expect(output.existsSync(), isFalse);
    } finally {
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    }
  });

  test("missing jobs are deleted idempotently", () {
    final dir = Directory.systemTemp.createTempSync("packer_missing_delete_");
    try {
      final manager = PackJobManager(
        dataDirectory: dir,
        maxConcurrent: 0,
        fileTtl: const Duration(hours: 1),
      );

      final result = manager.deleteJob("missing-job");

      expect(result.deleted, isTrue);
      expect(result.missing, isTrue);
    } finally {
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    }
  });

  test("missing jobs with orphan output directories are cleaned", () {
    final dir = Directory.systemTemp.createTempSync("packer_orphan_delete_");
    try {
      final manager = PackJobManager(
        dataDirectory: dir,
        maxConcurrent: 0,
        fileTtl: const Duration(hours: 1),
      );
      final orphan = Directory("${dir.path}/jobs/orphan-job")
        ..createSync(recursive: true);
      File("${orphan.path}/old.epub").writeAsStringSync("old");

      final result = manager.deleteJob("orphan-job");

      expect(result.deleted, isTrue);
      expect(result.missing, isTrue);
      expect(orphan.existsSync(), isFalse);
    } finally {
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    }
  });

  test("running jobs cannot be deleted before cancel", () {
    final dir = Directory.systemTemp.createTempSync("packer_running_delete_");
    try {
      final manager = PackJobManager(
        dataDirectory: dir,
        maxConcurrent: 0,
        fileTtl: const Duration(hours: 1),
      );
      final job = manager.createJob(CreateJobRequest(
        url: "https://example.invalid/novel/1.html",
        volumeIndexes: const [0],
        volumeRange: null,
        combineVolume: true,
        addChapterTitle: true,
      ));
      job.status = "running";

      final result = manager.deleteJob(job.id);

      expect(result.running, isTrue);
      expect(manager.getJob(job.id), isNotNull);
    } finally {
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    }
  });

  test("job events distinguish progress and full job payloads", () async {
    final job = PackJob(
      id: "job-events",
      url: "https://example.invalid/novel/1.html",
      createdAt: DateTime.now().toUtc(),
    );

    final progressFuture = job.events.first;
    job.touch(status: "running", message: "处理中", completed: 1, total: 3);
    final progress = await progressFuture;
    expect(progress["event"], "progress");
    expect((progress["data"] as Map)["percent"], closeTo(33.3, 0.2));

    final terminalFuture = job.events.first;
    job.touch(status: "canceled", message: "任务已取消");
    final terminal = await terminalFuture;
    expect(terminal["event"], "job");
    expect((terminal["data"] as Map)["status"], "canceled");
  });

  test("job progress can report realtime percent without completing chapters",
      () async {
    final job = PackJob(
      id: "job-percent",
      url: "https://example.invalid/novel/1.html",
      createdAt: DateTime.now().toUtc(),
    );

    final progressFuture = job.events.first;
    job.touch(
      status: "running",
      message: "正在处理图片",
      completed: 1,
      total: 10,
      percent: 18.5,
    );

    final progress = await progressFuture;
    final data = progress["data"] as Map;
    expect(data["completed"], 1);
    expect(data["percent"], closeTo(18.5, 0.01));
    expect(job.toManifestJson()["percent"], closeTo(18.5, 0.01));
  });

  test("canceled jobs preserve the latest realtime percent", () {
    final job = PackJob(
      id: "job-cancel-percent",
      url: "https://example.invalid/novel/1.html",
      createdAt: DateTime.now().toUtc(),
    );

    job.touch(
      status: "running",
      message: "正在处理图片",
      completed: 1,
      total: 10,
      percent: 18.5,
    );
    job.touch(status: "canceled", message: "任务已取消");

    expect(job.toJson()["percent"], closeTo(18.5, 0.01));
  });

  test("job subscriptions receive full job updates, progress, and terminal job",
      () async {
    final dir = Directory.systemTemp.createTempSync("packer_subscribe_test_");
    try {
      final manager = PackJobManager(
        dataDirectory: dir,
        maxConcurrent: 0,
        fileTtl: const Duration(hours: 1),
      );
      final job = manager.createJob(CreateJobRequest(
        url: "https://example.invalid/novel/1.html",
        volumeIndexes: const [0],
        volumeRange: null,
        combineVolume: true,
        addChapterTitle: true,
      ));
      final events = <Map<String, Object?>>[];
      final subscription = manager.subscribe(job.id).listen(events.add);

      await _waitForEventCount(events, 1);
      expect(events[0]["event"], "job");

      job.novel = {"id": "novel-1", "title": "测试小说"};
      job.catalog = {"volumes": <Object?>[]};
      job.publishJob();
      await _waitForEventCount(events, 2);
      expect(events[1]["event"], "job");
      expect(((events[1]["data"] as Map)["novel"] as Map)["title"], "测试小说");

      job.touch(
        status: "running",
        message: "正在处理",
        completed: 1,
        total: 3,
        forceEvent: true,
      );
      await _waitForEventCount(events, 3);
      expect(events[2]["event"], "progress");

      job.touch(status: "canceled", message: "任务已取消");
      await _waitForEventCount(events, 4);
      expect(events[3]["event"], "job");
      expect((events[3]["data"] as Map)["status"], "canceled");

      await subscription.cancel();
    } finally {
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    }
  });
}

Future<void> _waitForEventCount(
  List<Map<String, Object?>> events,
  int count,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 1));
  while (events.length < count && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(events.length, greaterThanOrEqualTo(count));
}

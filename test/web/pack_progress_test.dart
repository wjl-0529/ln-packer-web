import 'package:ln_packer_web/novel_packer.dart';
import 'package:test/test.dart';

void main() {
  test("PackProgress falls back to completed chapter percent", () {
    final progress = PackProgress(
      phase: "chapter-completed",
      message: "处理完成",
      completed: 2,
      total: 10,
    );

    expect(progress.completed, 2);
    expect(progress.percent, closeTo(20, 0.01));
  });

  test("PackProgress keeps completed chapters separate from realtime percent",
      () {
    final progress = PackProgress(
      phase: "images",
      message: "正在处理图片",
      completed: 1,
      total: 10,
      percent: 18.5,
    );

    expect(progress.completed, 1);
    expect(progress.percent, closeTo(18.5, 0.01));
    expect(progress.toJson()["percent"], closeTo(18.5, 0.01));
  });

  test("stage credits can move percent before the chapter is completed", () {
    final start = PackProgress(
      phase: "chapter-start",
      message: "章节开始",
      completed: 0,
      total: 10,
      percent: 0.5,
    );
    final body = PackProgress(
      phase: "chapter-body",
      message: "正文完成",
      completed: 0,
      total: 10,
      percent: 3.5,
    );
    final images = PackProgress(
      phase: "images",
      message: "图片完成",
      completed: 0,
      total: 10,
      percent: 9,
    );
    final completed = PackProgress(
      phase: "chapter-completed",
      message: "章节完成",
      completed: 1,
      total: 10,
    );

    expect(start.completed, 0);
    expect(body.completed, 0);
    expect(images.completed, 0);
    expect(start.percent, lessThan(body.percent));
    expect(body.percent, lessThan(images.percent));
    expect(images.percent, lessThanOrEqualTo(completed.percent));
    expect(completed.completed, 1);
    expect(completed.percent, closeTo(10, 0.01));
  });
}

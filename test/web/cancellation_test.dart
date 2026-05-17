import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ln_packer_web/scheduler/scheduler.dart';
import 'package:ln_packer_web/util/cancellation.dart';
import 'package:ln_packer_web/util/http_util.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

void main() {
  test("http requests return quickly when cancellation token is canceled",
      () async {
    final token = CancellationToken();
    final future = httpGetString(
      "https://example.invalid/slow",
      client: _SlowClient(),
      cancellationToken: token,
    );

    Timer(const Duration(milliseconds: 20), token.cancel);

    await expectLater(future, throwsA(isA<CancellationException>()));
  });

  test("scheduler pending work is failed on cancel", () async {
    final token = CancellationToken();
    final scheduler = Scheduler(
      1,
      const Duration(seconds: 30),
      cancellationToken: token,
    );

    unawaited(scheduler.run((_) async {
      await token.delay(const Duration(seconds: 10));
      return "first";
    }).catchError((_) => "canceled"));
    final pending = scheduler.run((_) => "second");

    Timer(const Duration(milliseconds: 20), token.cancel);
    scheduler.cancelPending();

    await expectLater(pending, throwsA(isA<CancellationException>()));
  });

  test("cancelable delay interrupts retry waits", () async {
    final token = CancellationToken();
    final future = httpGetString(
      "https://example.invalid/retry",
      client: _FailingClient(),
      cancellationToken: token,
    );

    Timer(const Duration(milliseconds: 20), token.cancel);

    await expectLater(future, throwsA(isA<CancellationException>()));
  });
}

class _SlowClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await Future.delayed(const Duration(seconds: 5));
    return http.StreamedResponse(
      Stream.value(utf8.encode("ok")),
      200,
    );
  }
}

class _FailingClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    throw const SocketException("offline");
  }
}

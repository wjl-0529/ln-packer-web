import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ln_packer_web/util/cancellation.dart';
import 'package:http/http.dart' as http;
import 'package:http/http.dart';

/// 默认超时时间 单位秒
const int defaultTimeout = 30;

/// 最大重试次数
const int defaultMaxAttempts = 5;

Future<T> _retry<T>(
  FutureOr<T> Function() fn, {
  int maxAttempts = defaultMaxAttempts,
  CancellationToken? cancellationToken,
}) async {
  var attempt = 0;
  while (true) {
    cancellationToken?.throwIfCanceled();
    try {
      final result = fn();
      if (result is Future<T>) {
        return cancellationToken == null
            ? await result
            : await cancellationToken.race(result);
      }
      return result;
    } catch (error) {
      if (error is CancellationException ||
          cancellationToken?.isCanceled == true) {
        throw const CancellationException();
      }
      final retryable = error is SocketException ||
          error is TimeoutException ||
          error is HandshakeException;
      attempt++;
      if (!retryable || attempt >= maxAttempts) {
        rethrow;
      }
      final delayMs = 300 * attempt;
      if (cancellationToken == null) {
        await Future.delayed(Duration(milliseconds: delayMs));
      } else {
        await cancellationToken.delay(Duration(milliseconds: delayMs));
      }
    }
  }
}

Future<Response> httpGetResponse(
  String url, {
  Map<String, String>? headers,
  Duration timeout = const Duration(seconds: defaultTimeout),
  http.Client? client,
  CancellationToken? cancellationToken,
}) {
  return _retry(
    () => (client == null
            ? http.get(Uri.parse(url), headers: headers)
            : client.get(Uri.parse(url), headers: headers))
        .timeout(timeout),
    cancellationToken: cancellationToken,
  );
}

Future<String> httpGetString(
  String url, {
  Map<String, String>? headers,
  Duration timeout = const Duration(seconds: defaultTimeout),
  Codec codec = const Utf8Codec(),
  int? maxAttempts,
  http.Client? client,
  CancellationToken? cancellationToken,
}) {
  return _retry(
    () => (client == null
            ? http.get(Uri.parse(url), headers: headers)
            : client.get(Uri.parse(url), headers: headers))
        .timeout(timeout),
    maxAttempts: maxAttempts ?? defaultMaxAttempts,
    cancellationToken: cancellationToken,
  ).then((response) {
    cancellationToken?.throwIfCanceled();
    return codec.decode(response.bodyBytes);
  });
}

Future<Uint8List> httpGetBytes(
  String url, {
  Map<String, String>? headers,
  Duration timeout = const Duration(seconds: defaultTimeout),
  Codec codec = const Utf8Codec(),
  int? maxAttempts,
  http.Client? client,
  CancellationToken? cancellationToken,
}) {
  return _retry(
    () => (client == null
            ? http.get(Uri.parse(url), headers: headers)
            : client.get(Uri.parse(url), headers: headers))
        .timeout(timeout),
    maxAttempts: maxAttempts ?? defaultMaxAttempts,
    cancellationToken: cancellationToken,
  ).then((response) {
    cancellationToken?.throwIfCanceled();
    return response.bodyBytes;
  });
}

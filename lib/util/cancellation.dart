import 'dart:async';

class CancellationException implements Exception {
  final String message;

  const CancellationException([this.message = "操作已取消"]);

  @override
  String toString() => message;
}

class CancellationToken {
  final Completer<void> _canceled = Completer<void>();

  bool get isCanceled => _canceled.isCompleted;

  Future<void> get canceled => _canceled.future;

  void cancel() {
    if (!_canceled.isCompleted) {
      _canceled.complete();
    }
  }

  void throwIfCanceled() {
    if (isCanceled) {
      throw const CancellationException();
    }
  }

  Future<T> race<T>(Future<T> future) {
    if (isCanceled) {
      return Future.error(const CancellationException());
    }
    return Future.any<T>([
      future,
      canceled.then<T>((_) => throw const CancellationException()),
    ]);
  }

  Future<void> delay(Duration duration) {
    if (duration <= Duration.zero) {
      throwIfCanceled();
      return Future.value();
    }
    return race(Future.delayed(duration));
  }
}

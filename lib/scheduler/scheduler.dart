import 'dart:async';
import 'dart:collection';

import 'package:ln_packer_web/util/cancellation.dart';

typedef SchedulerTask<R> = FutureOr<R?> Function(SchedulerController c);

class Scheduler {
  final Queue<SchedulerTask> _queue = Queue();
  final Map<int, _Result<dynamic>> _resultMap = {};
  final SchedulerController _controller = SchedulerController();
  final CancellationToken? cancellationToken;

  late final Duration _gap;

  bool _looping = false;
  Completer _completer = Completer<void>()..complete();

  Scheduler(int n, Duration per, {this.cancellationToken}) {
    if (n > 0 && per.inMilliseconds > 0) {
      Duration gap = Duration(milliseconds: (per.inMilliseconds / n).ceil());
      _gap = gap < Duration.zero ? Duration.zero : gap;
    } else {
      _gap = Duration.zero;
    }
  }

  Scheduler.unlimited({CancellationToken? cancellationToken})
      : this(0, Duration.zero, cancellationToken: cancellationToken);

  Future<R> run<R>(SchedulerTask<R> task) async {
    if (cancellationToken?.isCanceled == true) {
      return Future.error(const CancellationException());
    }
    _queue.add(task);
    _resultMap[task.hashCode] = _Result(_TaskStatus.pending);
    _loop();
    return _getResult(task.hashCode);
  }

  void cancelPending([Object? error]) {
    final cancelError = error ?? const CancellationException();
    while (_queue.isNotEmpty) {
      final task = _queue.removeFirst();
      final result = _resultMap[task.hashCode];
      if (result == null || result.status != _TaskStatus.pending) continue;
      result.error = cancelError;
      result.status = _TaskStatus.failed;
    }
  }

  Future<R> _getResult<R>(int taskHashCode) async {
    _Result<dynamic>? result = _resultMap[taskHashCode];
    if (result == null) {
      return Future.error("Task already completed or not found");
    }
    while (true) {
      if (cancellationToken?.isCanceled == true &&
          (result.status == _TaskStatus.pending ||
              result.status == _TaskStatus.inProgress)) {
        return Future.error(const CancellationException());
      }
      if (result.status == _TaskStatus.completed) {
        return result.value;
      }
      if (result.status == _TaskStatus.failed && result.error != null) {
        return Future.error(result.error!);
      }
      await Future.delayed(Duration(milliseconds: 1));
    }
  }

  void _loop() async {
    await _completer.future;
    _completer = Completer();
    if (_looping) {
      return;
    }
    _looping = true;
    while (_queue.isNotEmpty) {
      if (cancellationToken?.isCanceled == true) {
        cancelPending();
        break;
      }
      try {
        if (cancellationToken == null) {
          await Future.delayed(Duration(milliseconds: 1));
        } else {
          await cancellationToken!.delay(Duration(milliseconds: 1));
        }
      } on CancellationException {
        cancelPending();
        break;
      }
      if (_controller._pause) {
        continue;
      }
      SchedulerTask<dynamic> task = _queue.removeFirst();
      _Result<dynamic> result = _resultMap[task.hashCode]!;
      result.status = _TaskStatus.inProgress;
      FutureOr<dynamic> futureOr = task.call(_controller);
      if (futureOr is Future) {
        futureOr.then((onValue) {
          result.value = onValue;
          result.status = _TaskStatus.completed;
        }).catchError((e) {
          result.error = e;
          result.status = _TaskStatus.failed;
        });
      } else {
        result.value = await futureOr;
        result.status = _TaskStatus.completed;
      }
      try {
        if (cancellationToken == null) {
          await Future.delayed(_gap);
        } else {
          await cancellationToken!.delay(_gap);
        }
      } on CancellationException {
        cancelPending();
        break;
      }
    }
    _completer.complete();
    _looping = false;
  }

  Future<void> wait() async {
    while (_queue.isNotEmpty) {
      await Future.delayed(Duration(milliseconds: 1));
    }
    List<Future<void>> futures = [];
    for (var r in _resultMap.values) {
      futures.add(Future(() async {
        while (r.status == _TaskStatus.pending ||
            r.status == _TaskStatus.inProgress) {
          await Future.delayed(Duration(milliseconds: 1));
        }
      }));
    }
    await Future.wait(futures);
  }
}

enum _TaskStatus { pending, inProgress, completed, failed }

class _Result<R> {
  _TaskStatus status;
  R? value;
  Object? error;

  _Result(this.status);
}

class SchedulerController {
  bool _pause = false;

  void pause() {
    _pause = true;
  }

  void resume() {
    _pause = false;
  }
}

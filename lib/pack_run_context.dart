import 'package:ln_packer_web/scheduler/scheduler.dart';
import 'package:ln_packer_web/util/cancellation.dart';
import 'package:http/http.dart' as http;

class PackRunContext {
  final CancellationToken cancellationToken = CancellationToken();
  final http.Client httpClient = http.Client();
  final List<Scheduler> _schedulers = [];

  bool get isCanceled => cancellationToken.isCanceled;

  Scheduler createScheduler(int n, Duration per) {
    final scheduler = Scheduler(
      n,
      per,
      cancellationToken: cancellationToken,
    );
    _schedulers.add(scheduler);
    return scheduler;
  }

  Future<void> delay(Duration duration) {
    return cancellationToken.delay(duration);
  }

  void throwIfCanceled() {
    cancellationToken.throwIfCanceled();
  }

  void cancel() {
    cancellationToken.cancel();
    for (final scheduler in _schedulers) {
      scheduler.cancelPending();
    }
    httpClient.close();
  }

  void dispose() {
    httpClient.close();
  }
}

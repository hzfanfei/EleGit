import 'dart:async';

const kBookAssetConcurrency = 4;
const kBookAssetRetries = 2;

final bookAssetGate = AsyncGate(kBookAssetConcurrency);

class AsyncGate {
  AsyncGate(this.max);

  final int max;
  int _inFlight = 0;
  final List<Completer<void>> _waiters = [];

  Future<T> run<T>(Future<T> Function() fn) async {
    while (_inFlight >= max) {
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future;
    }
    _inFlight += 1;
    try {
      return await fn();
    } finally {
      _inFlight -= 1;
      if (_waiters.isNotEmpty) {
        _waiters.removeAt(0).complete();
      }
    }
  }
}

bool isTransientNetworkError(Object error) {
  final raw = error.toString().toLowerCase();
  return raw.contains('handshake') ||
      raw.contains('connection') ||
      raw.contains('socket') ||
      raw.contains('timeout') ||
      raw.contains('timed out') ||
      raw.contains('broken pipe') ||
      raw.contains('connection reset') ||
      raw.contains('failed host');
}

Future<T> retryTransient<T>(
  Future<T> Function() fn, {
  int retries = kBookAssetRetries,
}) async {
  Object? last;
  for (var attempt = 0; attempt <= retries; attempt++) {
    try {
      return await fn();
    } catch (err) {
      last = err;
      if (attempt == retries || !isTransientNetworkError(err)) rethrow;
      await Future<void>.delayed(Duration(milliseconds: 200 * (attempt + 1)));
    }
  }
  throw last ?? Exception('retry failed');
}

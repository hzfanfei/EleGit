import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/utils/async_gate.dart';

void main() {
  test('limits concurrent work and retries handshake-style flakes', () async {
    var inFlight = 0;
    var peak = 0;
    var attempts = 0;
    final remainingFails = <int, int>{1: 1};
    final gate = AsyncGate(2);

    Future<int> job(int id) {
      return gate.run(() {
        return retryTransient(() async {
          attempts += 1;
          inFlight += 1;
          if (inFlight > peak) peak = inFlight;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          inFlight -= 1;
          final left = remainingFails[id] ?? 0;
          if (left > 0) {
            remainingFails[id] = left - 1;
            throw Exception('HandshakeException: Connection terminated during handshake');
          }
          return id;
        }, retries: 2);
      });
    }

    final results = await Future.wait([job(1), job(2), job(3)]);
    expect(results, containsAll([1, 2, 3]));
    expect(peak, lessThanOrEqualTo(2));
    expect(attempts, greaterThan(3));
  });
}

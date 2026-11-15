// Runs the blocking shredder code in background isolates.
import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'shredder.dart';

Future<ShredPlan> scanInBackground(List<String> paths) =>
    Isolate.run(() => scanSelection(paths));

class _JobArgs {
  const _JobArgs(this.port, this.plan, this.stopFlagAddress);
  final SendPort port;
  final ShredPlan plan;
  final int stopFlagAddress;
}

void _jobMain(_JobArgs args) {
  final stopFlag = Pointer<Int32>.fromAddress(args.stopFlagAddress);
  final report = executePlan(
    args.plan,
    onProgress: args.port.send,
    shouldStop: () => stopFlag.value != 0,
  );
  args.port.send(report);
}

/// A running shred. The stop request lives in native memory because the worker
/// never returns to its event loop while it is writing.
class ShredJob {
  ShredJob._(this._stopFlag, this.progress, this.report);

  final Pointer<Int32> _stopFlag;

  final Stream<ShredProgress> progress;
  final Future<ShredReport> report;

  void stop() => _stopFlag.value = 1;

  static Future<ShredJob> start(ShredPlan plan) async {
    final stopFlag = calloc<Int32>();
    final port = ReceivePort();
    final progress = StreamController<ShredProgress>.broadcast();
    final report = Completer<ShredReport>();

    void finish(ShredReport result) {
      if (report.isCompleted) return;
      report.complete(result);
      port.close();
      progress.close();
      calloc.free(stopFlag);
    }

    port.listen((message) {
      switch (message) {
        case ShredProgress():
          progress.add(message);
        case ShredReport():
          finish(message);
        case null:
          // The worker exited without a report, so it crashed.
          finish(
            ShredReport(
              filesShredded: 0,
              foldersRemoved: 0,
              linksRemoved: 0,
              issues: const [
                ShredIssue(
                  '',
                  'The shredding process failed unexpectedly. '
                      'Some items may already be destroyed.',
                ),
              ],
              stopped: true,
            ),
          );
      }
    });

    await Isolate.spawn(
      _jobMain,
      _JobArgs(port.sendPort, plan, stopFlag.address),
      onExit: port.sendPort,
      onError: port.sendPort,
    );
    return ShredJob._(stopFlag, progress.stream, report.future);
  }
}

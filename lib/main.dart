import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/context_menu.dart';
import 'src/shred_job.dart';
import 'src/shredder.dart';

const _instanceChannel = MethodChannel('fileshredder/instance');

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();

  // Command-line switches for installers; they never show a window.
  if (args.length == 1 && (args[0] == '--register' || args[0] == '--unregister')) {
    final menu = ContextMenu(Platform.resolvedExecutable);
    if (args[0] == '--register') {
      exit(menu.enable() ? 0 : 1);
    }
    menu.disable();
    exit(0);
  }

  runApp(ShredderApp(initialPaths: args));
}

class ShredderApp extends StatelessWidget {
  const ShredderApp({super.key, this.initialPaths = const []});

  final List<String> initialPaths;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'File Shredder',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF455A64),
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: const Color(0xFF455A64),
        brightness: Brightness.dark,
      ),
      home: ShredderScreen(initialPaths: initialPaths),
    );
  }
}

enum _Phase { home, scanning, confirm, shredding, done }

class ShredderScreen extends StatefulWidget {
  const ShredderScreen({super.key, required this.initialPaths});

  final List<String> initialPaths;

  @override
  State<ShredderScreen> createState() => _ShredderScreenState();
}

class _ShredderScreenState extends State<ShredderScreen> {
  final ContextMenu _menu = ContextMenu(Platform.resolvedExecutable);

  late _Phase _phase;
  late bool _menuEnabled;
  late final bool _openedFromHome;

  final List<String> _selection = [];
  final List<String> _queued = [];
  Timer? _rescanTimer;
  int _scanId = 0;

  ShredPlan? _plan;
  ShredJob? _job;
  ShredProgress? _progress;
  ShredReport? _report;
  bool _stopping = false;

  @override
  void initState() {
    super.initState();
    _openedFromHome = widget.initialPaths.isEmpty;
    _menuEnabled = _menu.isEnabled;
    _phase = _openedFromHome ? _Phase.home : _Phase.scanning;
    if (!_openedFromHome) {
      _selection.addAll(widget.initialPaths);
      _rescanTimer = Timer(const Duration(milliseconds: 150), _scan);
    }

    _instanceChannel.setMethodCallHandler((call) async {
      if (call.method == 'pathsAvailable') await _takeForwardedPaths();
    });
    _takeForwardedPaths();
  }

  /// Explorer starts one process per selected item. The extra processes hand
  /// their paths to this window through the native runner.
  Future<void> _takeForwardedPaths() async {
    try {
      final paths = await _instanceChannel.invokeListMethod<String>('takePaths');
      if (paths != null && paths.isNotEmpty) _receivePaths(paths);
    } on MissingPluginException {
      // No native runner, as in widget tests.
    }
  }

  void _receivePaths(List<String> paths) {
    if (_phase == _Phase.shredding || _phase == _Phase.done) {
      setState(() => _queued.addAll(paths));
      return;
    }
    _selection.addAll(paths);
    setState(() => _phase = _Phase.scanning);
    // Wait briefly so a burst of processes results in a single scan.
    _rescanTimer?.cancel();
    _rescanTimer = Timer(const Duration(milliseconds: 150), _scan);
  }

  Future<void> _scan() async {
    final id = ++_scanId;
    final plan = await scanInBackground(List.of(_selection));
    if (!mounted || id != _scanId) return;
    setState(() {
      _plan = plan;
      _phase = _Phase.confirm;
    });
  }

  Future<void> _startShredding() async {
    final job = await ShredJob.start(_plan!);
    setState(() {
      _job = job;
      _phase = _Phase.shredding;
      _progress = null;
      _stopping = false;
    });
    job.progress.listen((value) {
      if (mounted) setState(() => _progress = value);
    });
    final report = await job.report;
    if (!mounted) return;
    setState(() {
      _report = report;
      _phase = _Phase.done;
    });
  }

  void _close() {
    if (_openedFromHome) {
      setState(() {
        _selection.clear();
        _phase = _Phase.home;
      });
    } else {
      exit(0);
    }
  }

  void _reviewQueued() {
    final paths = List.of(_queued);
    _queued.clear();
    _selection.clear();
    setState(() => _phase = _Phase.scanning);
    _receivePaths(paths);
  }

  void _toggleMenu() {
    if (_menuEnabled) {
      _menu.disable();
    } else if (!_menu.enable()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Windows refused the registry change.')),
      );
    }
    setState(() => _menuEnabled = _menu.isEnabled);
  }

  @override
  void dispose() {
    _rescanTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: switch (_phase) {
          _Phase.home => _buildHome(),
          _Phase.scanning => _buildScanning(),
          _Phase.confirm => _buildConfirm(),
          _Phase.shredding => _buildShredding(),
          _Phase.done => _buildDone(),
        },
      ),
    );
  }

  Widget _buildHome() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Image.asset('logo.png', width: 112, height: 112),
          const SizedBox(height: 20),
          Text(
            'File Shredder',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 12),
          const Text(
            'Right-click any file or folder in File Explorer and choose Shred. '
            'On Windows 11 it is under "Show more options".',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _toggleMenu,
            icon: Icon(_menuEnabled ? Icons.remove_circle_outline : Icons.add),
            label: Text(
              _menuEnabled
                  ? 'Remove "Shred" from context menu'
                  : 'Add "Shred" to context menu',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScanning() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('Reading selection...'),
        ],
      ),
    );
  }

  String _summary(ShredPlan plan) {
    final parts = [
      if (plan.fileCount > 0) _count(plan.fileCount, 'file'),
      if (plan.folderCount > 0) _count(plan.folderCount, 'folder'),
      if (plan.linkCount > 0) _count(plan.linkCount, 'link'),
    ];
    return '${parts.join(', ')} (${_formatBytes(plan.totalBytes)})';
  }

  Widget _buildConfirm() {
    final plan = _plan!;
    final colors = Theme.of(context).colorScheme;
    final hasWork = plan.entries.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: colors.error, size: 32),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                hasWork ? 'Permanently shred?' : 'Nothing can be shredded',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (hasWork) ...[
          Text(_summary(plan), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          const Text(
            'This cannot be undone. Nothing goes to the Recycle Bin.',
          ),
        ],
        const SizedBox(height: 12),
        Expanded(
          child: _PathList(
            children: [
              for (final path in plan.roots) _PathTile(path: path),
              for (final issue in plan.issues)
                _PathTile(path: issue.path, note: issue.message, skipped: true),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'On SSDs and cloud-synced folders, overwriting cannot guarantee that '
          'every physical copy is erased.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            OutlinedButton(
              autofocus: true,
              onPressed: _close,
              child: const Text('Cancel'),
            ),
            const SizedBox(width: 12),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: colors.error,
                foregroundColor: colors.onError,
              ),
              onPressed: hasWork ? _startShredding : null,
              child: const Text('Shred'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildShredding() {
    final progress = _progress;
    final hasBytes = progress != null && progress.bytesTotal > 0;
    final fraction = hasBytes ? progress.bytesDone / progress.bytesTotal : null;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          _stopping ? 'Stopping...' : 'Shredding...',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 16),
        LinearProgressIndicator(value: fraction),
        const SizedBox(height: 8),
        if (fraction != null) Text('${(fraction * 100).floor()}%'),
        const SizedBox(height: 4),
        Text(
          progress?.currentPath ?? '',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 24),
        Align(
          alignment: Alignment.centerRight,
          child: OutlinedButton(
            onPressed: _stopping
                ? null
                : () {
                    _job?.stop();
                    setState(() => _stopping = true);
                  },
            child: const Text('Stop'),
          ),
        ),
      ],
    );
  }

  Widget _buildDone() {
    final report = _report!;
    final colors = Theme.of(context).colorScheme;
    final clean = report.issues.isEmpty && !report.stopped;
    final results = [
      _count(report.filesShredded, 'file'),
      if (report.foldersRemoved > 0) _count(report.foldersRemoved, 'folder'),
      if (report.linksRemoved > 0) _count(report.linksRemoved, 'link'),
    ].join(', ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              clean ? Icons.check_circle_outline : Icons.error_outline,
              color: clean ? colors.primary : colors.error,
              size: 32,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                report.stopped
                    ? 'Stopped'
                    : clean
                    ? 'Shredded'
                    : 'Finished with problems',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text('Destroyed: $results.'),
        if (report.stopped)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text(
              'The file being processed when you stopped is damaged and '
              'cannot be recovered.',
            ),
          ),
        const SizedBox(height: 12),
        Expanded(
          child: report.issues.isEmpty
              ? const SizedBox.shrink()
              : _PathList(
                  children: [
                    for (final issue in report.issues)
                      _PathTile(
                        path: issue.path,
                        note: issue.message,
                        skipped: true,
                      ),
                  ],
                ),
        ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            onPressed: _queued.isEmpty ? _close : _reviewQueued,
            child: Text(_queued.isEmpty ? 'Close' : 'Review next selection'),
          ),
        ),
      ],
    );
  }
}

class _PathList extends StatelessWidget {
  const _PathList({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: ListView(children: children),
      ),
    );
  }
}

class _PathTile extends StatelessWidget {
  const _PathTile({required this.path, this.note, this.skipped = false});

  final String path;
  final String? note;
  final bool skipped;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: Icon(
        skipped ? Icons.block : Icons.insert_drive_file_outlined,
        size: 20,
      ),
      title: Text(path, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: note == null ? null : Text(note!),
    );
  }
}

String _count(int value, String noun) =>
    '$value $noun${value == 1 ? '' : 's'}';

String _formatBytes(int bytes) {
  const units = ['bytes', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return unit == 0 ? '$bytes bytes' : '${value.toStringAsFixed(1)} ${units[unit]}';
}

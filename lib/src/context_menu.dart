// Adds or removes the Explorer "Shred" verb for the current user. Writing to
// HKCU needs no administrator rights.
import 'win32.dart';

class ContextMenu {
  const ContextMenu(
    this.executablePath, {
    this.classesKey = r'Software\Classes',
  });

  final String executablePath;
  final String classesKey;

  static const _verb = r'shell\FileShredder.Shred';

  List<String> get _keys => [
    '$classesKey\\*\\$_verb',
    '$classesKey\\Directory\\$_verb',
  ];

  String get _command => '"$executablePath" "%1"';

  /// True only when both verbs point at this exact executable, so a moved or
  /// rebuilt copy is offered the chance to register itself again.
  bool get isEnabled =>
      _keys.every((key) => regGetString('$key\\command', null) == _command);

  /// Returns false if the registry refused any of the writes.
  bool enable() {
    var ok = true;
    for (final key in _keys) {
      // Player lifts Explorer's 15-item limit on multi-selection.
      ok &= regSetString(key, 'MUIVerb', 'Shred') == 0;
      ok &= regSetString(key, 'Icon', '"$executablePath",0') == 0;
      ok &= regSetString(key, 'MultiSelectModel', 'Player') == 0;
      ok &= regSetString('$key\\command', null, _command) == 0;
    }
    return ok;
  }

  void disable() {
    for (final key in _keys) {
      regDeleteTree(key);
    }
  }
}

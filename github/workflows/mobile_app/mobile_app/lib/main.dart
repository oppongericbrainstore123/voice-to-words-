import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:record/record.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:sqflite/sqflite.dart';

// ============================================================
// APP START + THEME + ERROR CATCHING
// ============================================================

class AppErrors {
  static final ValueNotifier<String?> last = ValueNotifier(null);
  static void report(String message) => last.value = message;
}

String fmtDuration(Duration d) {
  final m = d.inMinutes.toString().padLeft(2, '0');
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
}

void main() {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    FlutterError.onError = (d) => AppErrors.report(d.exceptionAsString());
    try {
      await AppSettings.load();
    } catch (_) {}
    runApp(const VoiceNotesApp());
  }, (e, s) => AppErrors.report('$e'));
}

class AppSettings {
  static final ValueNotifier<ThemeMode> themeMode =
      ValueNotifier(ThemeMode.system);

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('theme');
    themeMode.value = ThemeMode.values.firstWhere(
      (m) => m.name == saved,
      orElse: () => ThemeMode.system,
    );
  }

  static Future<void> setTheme(ThemeMode mode) async {
    themeMode.value = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('theme', mode.name);
  }
}

class VoiceNotesApp extends StatelessWidget {
  const VoiceNotesApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppSettings.themeMode,
      builder: (_, mode, __) => MaterialApp(
        title: 'Voice Notes',
        themeMode: mode,
        theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
        darkTheme: ThemeData(
          colorSchemeSeed: Colors.indigo,
          brightness: Brightness.dark,
          useMaterial3: true,
        ),
        home: const RecorderScreen(),
      ),
    );
  }
}

// ============================================================
// DATABASE
// ============================================================

class Note {
  int? id;
  String title;
  String transcript;
  String? audioPath;
  DateTime createdAt;
  String? translation;
  String? translationLang;
  String? locale;

  Note({
    this.id,
    required this.title,
    required this.transcript,
    this.audioPath,
    required this.createdAt,
    this.translation,
    this.translationLang,
    this.locale,
  });

  Map<String, Object?> toMap() => {
        'title': title,
        'transcript': transcript,
        'audio_path': audioPath,
        'created_at': createdAt.millisecondsSinceEpoch,
        'translation': translation,
        'translation_lang': translationLang,
        'locale': locale,
      };

  factory Note.fromMap(Map<String, Object?> m) => Note(
        id: m['id'] as int,
        title: m['title'] as String,
        transcript: m['transcript'] as String,
        audioPath: m['audio_path'] as String?,
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int),
        translation: m['translation'] as String?,
        translationLang: m['translation_lang'] as String?,
        locale: m['locale'] as String?,
      );
}

class NoteDb {
  NoteDb._();
  static final NoteDb instance = NoteDb._();

  Database? _db;

  Future<Database> get _database async => _db ??= await _open();

  Future<Database> _open() async {
    final path = p.join(await getDatabasesPath(), 'notes.db');
    return openDatabase(
      path,
      version: 2,
      onCreate: (db, _) => db.execute('''
        CREATE TABLE notes(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          title TEXT NOT NULL,
          transcript TEXT NOT NULL,
          audio_path TEXT,
          created_at INTEGER NOT NULL,
          translation TEXT,
          translation_lang TEXT,
          locale TEXT
        )
      '''),
      onUpgrade: (db, oldVersion, _) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE notes ADD COLUMN translation TEXT');
          await db.execute('ALTER TABLE notes ADD COLUMN translation_lang TEXT');
          await db.execute('ALTER TABLE notes ADD COLUMN locale TEXT');
        }
      },
    );
  }

  Future<int> insert(Note note) async =>
      (await _database).insert('notes', note.toMap());

  Future<void> update(Note note) async {
    final db = await _database;
    await db.update('notes', note.toMap(), where: 'id = ?', whereArgs: [note.id]);
  }

  Future<List<Note>> all({String query = ''}) async {
    final db = await _database;
    final q = '%$query%';
    final rows = await db.query(
      'notes',
      where: query.isEmpty
          ? null
          : 'title LIKE ? OR transcript LIKE ? OR translation LIKE ?',
      whereArgs: query.isEmpty ? null : [q, q, q],
      orderBy: 'created_at DESC',
    );
    return rows.map(Note.fromMap).toList();
  }

  Future<void> delete(Note note) async {
    final db = await _database;
    await db.delete('notes', where: 'id = ?', whereArgs: [note.id]);
    final path = note.audioPath;
    if (path != null) {
      final f = File(path);
      if (await f.exists()) await f.delete();
    }
  }
}

// ============================================================
// AUDIO FILES (PCM -> WAV)
// ============================================================

class AudioFiles {
  static Uint8List pcmToWav(Uint8List pcm, {int sampleRate = 16000}) {
    final h = ByteData(44);
    void s(int o, String t) {
      for (var i = 0; i < t.length; i++) {
        h.setUint8(o + i, t.codeUnitAt(i));
      }
    }

    s(0, 'RIFF');
    h.setUint32(4, 36 + pcm.length, Endian.little);
    s(8, 'WAVE');
    s(12, 'fmt ');
    h.setUint32(16, 16, Endian.little);
    h.setUint16(20, 1, Endian.little);
    h.setUint16(22, 1, Endian.little);
    h.setUint32(24, sampleRate, Endian.little);
    h.setUint32(28, sampleRate * 2, Endian.little);
    h.setUint16(32, 2, Endian.little);
    h.setUint16(34, 16, Endian.little);
    s(36, 'data');
    h.setUint32(40, pcm.length, Endian.little);

    final b = BytesBuilder(copy: false)
      ..add(h.buffer.asUint8List())
      ..add(pcm);
    return b.toBytes();
  }

  static Future<String> saveWav(Uint8List pcm) async {
    final dir = await getApplicationDocumentsDirectory();
    final path =
        '${dir.path}/note_${DateTime.now().millisecondsSinceEpoch}.wav';
    await File(path).writeAsBytes(pcmToWav(pcm));
    return path;
  }
}

// ============================================================
// VOICE ISOLATION (optional filter for the saved audio)
// ============================================================

class VoiceIsolator {
  static const int _frame = 320;
  final Float64List _buf = Float64List(_frame);

  double _px = 0, _py = 0;
  double _floor = -1;
  double _level = 1500;
  double _gain = 0.3;
  double _makeup = 1;

  void reset() {
    _px = 0;
    _py = 0;
    _floor = -1;
    _level = 1500;
    _gain = 0.3;
    _makeup = 1;
  }

  Uint8List process(Uint8List input) {
    final n = input.length ~/ 2;
    final inp = ByteData.sublistView(input);
    final out = ByteData(n * 2);

    for (var start = 0; start < n; start += _frame) {
      final len = min(_frame, n - start);
      final f = _buf;
      double sum = 0;

      for (var i = 0; i < len; i++) {
        final x = inp.getInt16((start + i) * 2, Endian.little).toDouble();
        final y = 0.96 * (_py + x - _px);
        _px = x;
        _py = y;
        f[i] = y;
        sum += y * y;
      }

      final rms = sqrt(sum / len);
      if (_floor < 0) _floor = max(rms, 50);

      final speech = rms > _floor * 2.0 && rms > 120;

      if (rms < _floor) {
        _floor = 0.9 * _floor + 0.1 * rms;
      } else if (!speech) {
        _floor = min(_floor * 1.0005, rms);
      }
      _floor = max(_floor, 30);

      final targetGain = speech ? 1.0 : 0.3;
      final newGain =
          _gain + (targetGain - _gain) * (targetGain > _gain ? 0.6 : 0.15);

      if (speech) {
        _level = 0.95 * _level + 0.05 * rms;
        final want = (3000 / _level).clamp(1.0, 3.0).toDouble();
        _makeup = 0.9 * _makeup + 0.1 * want;
      }

      for (var i = 0; i < len; i++) {
        final t = (i + 1) / len;
        final g = (_gain + (newGain - _gain) * t) * _makeup;
        final v = (f[i] * g).round().clamp(-32768, 32767).toInt();
        out.setInt16((start + i) * 2, v, Endian.little);
      }
      _gain = newGain;
    }
    return out.buffer.asUint8List();
  }
}

// ============================================================
// TRANSLATION
// ============================================================

class TranslationException implements Exception {
  final String message;
  TranslationException(this.message);
  @override
  String toString() => message;
}

class TranslationService {
  static OnDeviceTranslatorModelManager? _managerInstance;
  static OnDeviceTranslatorModelManager get _manager =>
      _managerInstance ??= OnDeviceTranslatorModelManager();

  static List<TranslateLanguage> get languages => TranslateLanguage.values;

  static String label(TranslateLanguage l) =>
      l.name[0].toUpperCase() + l.name.substring(1);

  static TranslateLanguage fromLocale(String? locale) {
    final code = (locale ?? 'en').split(RegExp(r'[_-]')).first;
    return TranslateLanguage.values.firstWhere(
      (l) => l.bcpCode == code,
      orElse: () => TranslateLanguage.english,
    );
  }

  static Future<bool> hasInternet() async {
    try {
      final r = await InternetAddress.lookup('google.com')
          .timeout(const Duration(seconds: 6));
      return r.isNotEmpty && r.first.rawAddress.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _ensureModel(
    TranslateLanguage l,
    void Function(String) status,
  ) async {
    bool have = false;
    try {
      have = await _manager.isModelDownloaded(l.bcpCode);
    } catch (_) {}
    if (have) return;

    if (!await hasInternet()) {
      throw TranslationException(
          'No internet. Connect to Wi-Fi or mobile data once so the app can '
          'download the ${label(l)} language pack (about 30 MB). After that, '
          'translation works offline.');
    }

    status('Downloading ${label(l)} pack (about 30 MB)...');
    bool ok = false;
    try {
      ok = await _manager
          .downloadModel(l.bcpCode, isWifiRequired: false)
          .timeout(const Duration(minutes: 5), onTimeout: () => false);
    } catch (e) {
      throw TranslationException(
          'The ${label(l)} language pack could not be downloaded: $e');
    }
    if (!ok) {
      throw TranslationException(
          'The ${label(l)} language pack did not finish downloading. '
          'Check your connection and try again.');
    }
  }

  static Future<String> translate(
    String text,
    TranslateLanguage from,
    TranslateLanguage to, {
    void Function(String)? onStatus,
  }) async {
    final status = onStatus ?? (String s) {};
    if (from == to) return text;

    await _ensureModel(from, status);
    await _ensureModel(to, status);

    status('Translating...');
    final translator =
        OnDeviceTranslator(sourceLanguage: from, targetLanguage: to);
    try {
      final outLines = <String>[];
      for (final line in text.split('\n')) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) {
          outLines.add('');
          continue;
        }
        final words = trimmed.split(RegExp(r'\s+'));
        final pieces = <String>[];
        for (var i = 0; i < words.length; i += 60) {
          final chunk = words.sublist(i, min(i + 60, words.length)).join(' ');
          pieces.add(await translator.translateText(chunk));
        }
        outLines.add(pieces.join(' '));
      }
      return outLines.join('\n');
    } finally {
      await translator.close();
    }
  }
}

// ============================================================
// EXPORT (PDF, DOCX, TXT)
// ============================================================

class ExportService {
  static String _fileName(String title, String ext) {
    final clean = title.replaceAll(RegExp(r'[^\w\- ]'), '').trim();
    return '${clean.isEmpty ? 'voice_note' : clean}.$ext';
  }

  static Future<File> _tmp(String title, String ext) async {
    final dir = await getTemporaryDirectory();
    return File('${dir.path}/${_fileName(title, ext)}');
  }

  static Future<File> toTxt(String title, String body) async {
    final f = await _tmp(title, 'txt');
    return f.writeAsString('$title\n\n$body');
  }

  /// For non-Latin scripts, add assets/fonts/NotoSans-Regular.ttf
  /// and list it in pubspec.yaml under flutter: assets:
  static Future<File> toPdf(String title, String body) async {
    pw.ThemeData? theme;
    try {
      final data = await rootBundle.load('assets/fonts/NotoSans-Regular.ttf');
      theme = pw.ThemeData.withFont(base: pw.Font.ttf(data));
    } catch (_) {}
    final doc = pw.Document(theme: theme);
    doc.addPage(pw.MultiPage(
      build: (_) => [
        pw.Header(level: 0, text: title),
        ...body.split('\n').map((line) => pw.Paragraph(text: line)),
      ],
    ));
    final f = await _tmp(title, 'pdf');
    return f.writeAsBytes(await doc.save());
  }

  static Future<File> toDocx(String title, String body) async {
    String esc(String s) =>
        s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

    final paras = StringBuffer()
      ..write('<w:p><w:r><w:rPr><w:b/><w:sz w:val="36"/></w:rPr>'
          '<w:t xml:space="preserve">${esc(title)}</w:t></w:r></w:p>');
    for (final line in body.split('\n')) {
      paras.write(
          '<w:p><w:r><w:t xml:space="preserve">${esc(line)}</w:t></w:r></w:p>');
    }

    const xml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>';
    final Map<String, String> files = {
      '[Content_Types].xml':
          '$xml<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
              '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
              '<Default Extension="xml" ContentType="application/xml"/>'
              '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
              '</Types>',
      '_rels/.rels':
          '$xml<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
              '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
              '</Relationships>',
      'word/document.xml':
          '$xml<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
              '<w:body>$paras</w:body></w:document>',
    };

    final archive = Archive();
    files.forEach((name, content) {
      final bytes = utf8.encode(content);
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    });
    final out = ZipEncoder().encode(archive)!;
    final f = await _tmp(title, 'docx');
    return f.writeAsBytes(out);
  }

  static Future<void> share(File file) async {
    await Share.shareXFiles([XFile(file.path)]);
  }
}

// ============================================================
// BACKUP + RESTORE
// ============================================================

class BackupService {
  static Future<void> backup() async {
    final notes = await NoteDb.instance.all();
    final archive = Archive();
    final list = [];

    for (final n in notes) {
      final m = n.toMap();
      final path = n.audioPath;
      if (path != null && await File(path).exists()) {
        final bytes = await File(path).readAsBytes();
        final name = p.basename(path);
        archive.addFile(ArchiveFile('audio/$name', bytes.length, bytes));
        m['audio_path'] = name;
      } else {
        m['audio_path'] = null;
      }
      list.add(m);
    }

    final json = utf8.encode(jsonEncode(list));
    archive.addFile(ArchiveFile('notes.json', json.length, json));

    final out = ZipEncoder().encode(archive)!;
    final dir = await getTemporaryDirectory();
    final d = DateTime.now();
    final stamp =
        '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';
    final file = File('${dir.path}/voice_notes_backup_$stamp.zip');
    await file.writeAsBytes(out);
    await Share.shareXFiles([XFile(file.path)]);
  }

  static Future<int> restore() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
    );
    final path = res?.files.single.path;
    if (path == null) return 0;

    final archive = ZipDecoder().decodeBytes(await File(path).readAsBytes());
    final jsonFile = archive.findFile('notes.json');
    if (jsonFile == null) throw Exception('Not a Voice Notes backup');

    final list =
        jsonDecode(utf8.decode(jsonFile.content as List<int>)) as List;
    final docs = await getApplicationDocumentsDirectory();

    final existing = await NoteDb.instance.all();
    final seen = existing
        .map((n) => '${n.createdAt.millisecondsSinceEpoch}|${n.transcript}')
        .toSet();

    var count = 0;
    for (final raw in list) {
      final m = Map<String, Object?>.from(raw as Map);
      final note = Note.fromMap({...m, 'id': 0});
      final key = '${note.createdAt.millisecondsSinceEpoch}|${note.transcript}';
      if (seen.contains(key)) continue;

      final audioName = m['audio_path'] as String?;
      note.audioPath = null;
      if (audioName != null) {
        final safe = p.basename(audioName);
        final af = archive.findFile('audio/$safe');
        if (af != null) {
          final dest = '${docs.path}/$safe';
          await File(dest).writeAsBytes(af.content as List<int>);
          note.audioPath = dest;
        }
      }
      note.id = null;
      await NoteDb.instance.insert(note);
      count++;
    }
    return count;
  }
}

// ============================================================
// AUDIO PLAYER BAR (play / pause / seek)
// ============================================================

class PlayerBar extends StatefulWidget {
  final String path;
  const PlayerBar({super.key, required this.path});

  @override
  State<PlayerBar> createState() => _PlayerBarState();
}

class _PlayerBarState extends State<PlayerBar> {
  final AudioPlayer _player = AudioPlayer();
  final List<StreamSubscription> _subs = [];
  PlayerState _state = PlayerState.stopped;
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;

  @override
  void initState() {
    super.initState();
    _subs.addAll([
      _player.onPlayerStateChanged.listen((s) {
        if (mounted) setState(() => _state = s);
      }),
      _player.onPositionChanged.listen((d) {
        if (mounted) setState(() => _pos = d);
      }),
      _player.onDurationChanged.listen((d) {
        if (mounted) setState(() => _dur = d);
      }),
      _player.onPlayerComplete.listen((_) {
        if (mounted) setState(() => _pos = Duration.zero);
      }),
    ]);
    _player.setSourceDeviceFile(widget.path).catchError((_) {});
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    try {
      if (_state == PlayerState.playing) {
        await _player.pause();
      } else if (_state == PlayerState.paused) {
        await _player.resume();
      } else {
        await _player.play(DeviceFileSource(widget.path));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Cannot play audio: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final maxMs = max(_dur.inMilliseconds, 1);
    final value = min(_pos.inMilliseconds, maxMs).toDouble();
    return Row(
      children: [
        IconButton.filledTonal(
          icon: Icon(_state == PlayerState.playing
              ? Icons.pause
              : Icons.play_arrow),
          onPressed: _toggle,
        ),
        Expanded(
          child: Slider(
            value: value,
            max: maxMs.toDouble(),
            onChanged: (v) => _player.seek(Duration(milliseconds: v.toInt())),
          ),
        ),
        Text('${fmtDuration(_pos)} / ${fmtDuration(_dur)}',
            style: Theme.of(context).textTheme.labelSmall),
      ],
    );
  }
}

// ============================================================
// SETTINGS SCREEN
// ============================================================

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _busy = false;

  Future<void> _run(Future<String> Function() job) async {
    setState(() => _busy = true);
    String msg;
    try {
      msg = await job();
    } catch (e) {
      msg = 'Failed: $e';
    }
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Theme', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ValueListenableBuilder<ThemeMode>(
            valueListenable: AppSettings.themeMode,
            builder: (_, mode, __) => SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(value: ThemeMode.system, label: Text('System')),
                ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
              ],
              selected: {mode},
              onSelectionChanged: (s) => AppSettings.setTheme(s.first),
            ),
          ),
          const SizedBox(height: 24),
          Text('Backup', style: Theme.of(context).textTheme.titleMedium),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.backup),
            title: const Text('Back up all notes'),
            subtitle: const Text('Saves text, translations and audio as a .zip'),
            enabled: !_busy,
            onTap: () => _run(() async {
              await BackupService.backup();
              return 'Backup created';
            }),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.restore),
            title: const Text('Restore from backup'),
            subtitle: const Text('Pick a backup .zip. Existing notes are kept.'),
            enabled: !_busy,
            onTap: () => _run(() async {
              final n = await BackupService.restore();
              return 'Restored $n notes';
            }),
          ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(top: 16),
              child: LinearProgressIndicator(),
            ),
        ],
      ),
    );
  }
}

// ============================================================
// NOTES LIST SCREEN
// ============================================================

class NotesScreen extends StatefulWidget {
  const NotesScreen({super.key});

  @override
  State<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends State<NotesScreen> {
  List<Note> _notes = [];
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final notes = await NoteDb.instance.all(query: _query);
    if (mounted) setState(() => _notes = notes);
  }

  Future<void> _delete(Note n) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this note?'),
        content: const Text('The text and its audio will be removed.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    await NoteDb.instance.delete(n);
    _load();
  }

  String _date(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          decoration: const InputDecoration(
            hintText: 'Search notes...',
            border: InputBorder.none,
            prefixIcon: Icon(Icons.search),
          ),
          onChanged: (v) {
            _query = v;
            _load();
          },
        ),
      ),
      body: _notes.isEmpty
          ? const Center(child: Text('No notes yet'))
          : ListView.builder(
              itemCount: _notes.length,
              itemBuilder: (context, i) {
                final n = _notes[i];
                return ListTile(
                  title: Text(n.title,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    '${_date(n.createdAt)}\n${n.transcript}',
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  isThreeLine: true,
                  onTap: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => EditorScreen(note: n)),
                    );
                    _load();
                  },
                  leading: Icon(
                      n.audioPath == null ? Icons.notes : Icons.graphic_eq),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _delete(n),
                  ),
                );
              },
            ),
    );
  }
}

// ============================================================
// EDITOR SCREEN (play, edit, translate, export)
// ============================================================

class EditorScreen extends StatefulWidget {
  final Note note;
  const EditorScreen({super.key, required this.note});

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  late final TextEditingController _title;
  late final TextEditingController _text;
  late final TextEditingController _translation;
  late TranslateLanguage _from;
  late TranslateLanguage _to;
  bool _busy = false;
  String _status = '';

  @override
  void initState() {
    super.initState();
    final n = widget.note;
    _title = TextEditingController(text: n.title);
    _text = TextEditingController(text: n.transcript);
    _translation = TextEditingController(text: n.translation ?? '');
    _from = TranslationService.fromLocale(n.locale);
    _to = TranslateLanguage.values.firstWhere(
      (l) => l.bcpCode == n.translationLang,
      orElse: () => _from == TranslateLanguage.english
          ? TranslateLanguage.spanish
          : TranslateLanguage.english,
    );
  }

  @override
  void dispose() {
    _title.dispose();
    _text.dispose();
    _translation.dispose();
    super.dispose();
  }

  void _msg(String s) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  Future<void> _showProblem(String m) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Translation problem'),
        content: SingleChildScrollView(child: SelectableText(m)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
        ],
      ),
    );
  }

  Future<void> _save({bool quiet = false}) async {
    final n = widget.note;
    n.title = _title.text.trim().isEmpty ? 'Voice note' : _title.text.trim();
    n.transcript = _text.text;
    n.translation = _translation.text.isEmpty ? null : _translation.text;
    n.translationLang = _translation.text.isEmpty ? null : _to.bcpCode;
    await NoteDb.instance.update(n);
    if (!quiet && mounted) _msg('Saved');
  }

  Future<void> _translate() async {
    if (_text.text.trim().isEmpty) return;
    if (_from == _to) {
      _msg('Choose two different languages.');
      return;
    }
    setState(() {
      _busy = true;
      _status = 'Starting...';
    });
    try {
      final result = await TranslationService.translate(
        _text.text,
        _from,
        _to,
        onStatus: (s) {
          if (mounted) setState(() => _status = s);
        },
      );
      _translation.text = result;
      await _save(quiet: true);
    } on TranslationException catch (e) {
      await _showProblem(e.message);
    } catch (e) {
      await _showProblem('Translation failed: $e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = '';
        });
      }
    }
  }

  String get _exportBody {
    final t = _translation.text.trim();
    if (t.isEmpty) return _text.text;
    return '${_text.text}\n\n'
        'Translation (${TranslationService.label(_to)}):\n$t';
  }

  Future<void> _export(String kind) async {
    await _save(quiet: true);
    final title =
        _title.text.trim().isEmpty ? 'Voice note' : _title.text.trim();
    try {
      final file = switch (kind) {
        'pdf' => await ExportService.toPdf(title, _exportBody),
        'docx' => await ExportService.toDocx(title, _exportBody),
        _ => await ExportService.toTxt(title, _exportBody),
      };
      await ExportService.share(file);
    } catch (e) {
      _msg('Export failed: $e');
    }
  }

  Widget _langPicker(String label, TranslateLanguage value,
      ValueChanged<TranslateLanguage> onChanged) {
    return Expanded(
      child: DropdownButtonFormField<TranslateLanguage>(
        value: value,
        isExpanded: true,
        decoration: InputDecoration(labelText: label),
        items: TranslationService.languages
            .map((l) => DropdownMenuItem(
                  value: l,
                  child: Text(TranslationService.label(l)),
                ))
            .toList(),
        onChanged: (v) => onChanged(v!),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final audio = widget.note.audioPath;
    final hasAudio = audio != null && File(audio).existsSync();
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _save(quiet: true);
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Edit note'),
          actions: [
            IconButton(icon: const Icon(Icons.save), onPressed: _save),
            PopupMenuButton<String>(
              icon: const Icon(Icons.ios_share),
              onSelected: _export,
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'pdf', child: Text('Export as PDF')),
                PopupMenuItem(
                    value: 'docx', child: Text('Export as Word (.docx)')),
                PopupMenuItem(
                    value: 'txt', child: Text('Export as text (.txt)')),
              ],
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (hasAudio) ...[
              PlayerBar(key: ValueKey(audio), path: audio),
              const SizedBox(height: 8),
            ],
            TextField(
              controller: _title,
              decoration: const InputDecoration(labelText: 'Title'),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _text,
              minLines: 6,
              maxLines: null,
              decoration: const InputDecoration(
                labelText: 'Transcript',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                _langPicker('From', _from, (v) => setState(() => _from = v)),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Icon(Icons.arrow_forward),
                ),
                _langPicker('To', _to, (v) => setState(() => _to = v)),
              ],
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy ? null : _translate,
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.translate),
              label: Text(_busy
                  ? (_status.isEmpty ? 'Working...' : _status)
                  : 'Translate'),
            ),
            const SizedBox(height: 6),
            Text(
              'Needs internet once for each language. Works offline after that.',
              style: Theme.of(context).textTheme.labelSmall,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _translation,
              minLines: 4,
              maxLines: null,
              decoration: const InputDecoration(
                labelText: 'Translation (editable)',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// WAVEFORM
// ============================================================

class WavePainter extends CustomPainter {
  final List<double> values;
  final int slots;
  final Color color;
  WavePainter(this.values, this.slots, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeCap = StrokeCap.round
      ..strokeWidth = max(2.0, size.width / slots * 0.55);
    final step = size.width / slots;
    final mid = size.height / 2;
    final n = values.length;
    for (var i = 0; i < n; i++) {
      final x = size.width - (n - i) * step + step / 2;
      final h = max(4.0, values[i] * size.height);
      canvas.drawLine(Offset(x, mid - h / 2), Offset(x, mid + h / 2), paint);
    }
  }

  @override
  bool shouldRepaint(covariant WavePainter old) => true;
}

// ============================================================
// SPEAKING LANGUAGE PICKER (searchable list)
// ============================================================

class LanguageSheet extends StatefulWidget {
  final List<LocaleName> locales;
  final String? selected;
  const LanguageSheet({
    super.key,
    required this.locales,
    required this.selected,
  });

  @override
  State<LanguageSheet> createState() => _LanguageSheetState();
}

class _LanguageSheetState extends State<LanguageSheet> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final q = _q.toLowerCase();
    final list = widget.locales
        .where((l) =>
            l.name.toLowerCase().contains(q) ||
            l.localeId.toLowerCase().contains(q))
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    final h = MediaQuery.of(context).size.height * 0.75;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: h,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Search language (French, Yoruba, Hindi...)',
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) => setState(() => _q = v),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '${list.length} languages available on this phone',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: list.length,
                itemBuilder: (context, i) {
                  final l = list[i];
                  final sel = l.localeId == widget.selected;
                  return ListTile(
                    title: Text(l.name),
                    subtitle: Text(l.localeId),
                    trailing:
                        sel ? const Icon(Icons.check, color: Colors.green) : null,
                    onTap: () => Navigator.pop(context, l.localeId),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// RECORDER SCREEN (home)
//
// Default: live text only. The phone's speech engine uses the
// microphone alone, so words appear as you speak.
//
// Optional "Also save audio": records sound for playback, but the
// phone usually lets only one app part use the microphone, so
// live text may stop on some phones when this is on.
// ============================================================

enum RecState { idle, recording, paused }

class RecorderScreen extends StatefulWidget {
  const RecorderScreen({super.key});

  @override
  State<RecorderScreen> createState() => _RecorderScreenState();
}

class _RecorderScreenState extends State<RecorderScreen> {
  static const int _rate = 16000;
  static const int _slots = 48;

  final SpeechToText _speech = SpeechToText();
  AudioRecorder? _recInstance;
  AudioRecorder get _rec => _recInstance ??= AudioRecorder();
  final VoiceIsolator _iso = VoiceIsolator();
  StreamSubscription<Uint8List>? _sub;
  final BytesBuilder _all = BytesBuilder(copy: false);
  final Stopwatch _sw = Stopwatch();
  Timer? _timer;

  final ValueNotifier<int> _tick = ValueNotifier(0);
  final List<double> _waves = [];
  double _db = -90;
  double _recLevel = 0;
  double _peakAll = 0;
  final ScrollController _scroll = ScrollController();

  RecState _state = RecState.idle;
  bool _saving = false;
  bool _saveAudio = false; // the switch on the home screen
  bool _audioOn = false; // what this recording actually uses
  bool _isolate = false;
  bool _speechReady = false;
  bool _restarting = false;
  List<LocaleName> _locales = [];
  String? _localeId;
  String _committed = '';
  String _partial = '';
  String _lastFinal = '';
  String _engine = 'idle';
  String _lastErr = '';
  int _results = 0;
  String? _error;
  String? _previewPath;
  Note? _saved;
  String? _saveNote;

  String get _fullText =>
      [_committed, _partial].where((s) => s.isNotEmpty).join(' ');

  @override
  void initState() {
    super.initState();
    _loadPrefs().then((_) => _initSpeech());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _sub?.cancel();
    _recInstance?.dispose();
    try {
      _speech.cancel();
    } catch (_) {}
    _tick.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _localeId = prefs.getString('locale');
        _saveAudio = prefs.getBool('save_audio') ?? false;
        _isolate = prefs.getBool('isolate_v2') ?? false;
      });
    } catch (_) {}
  }

  Future<void> _savePrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_localeId != null) await prefs.setString('locale', _localeId!);
      await prefs.setBool('save_audio', _saveAudio);
      await prefs.setBool('isolate_v2', _isolate);
    } catch (_) {}
  }

  void _setError(String m) {
    if (mounted) setState(() => _error = m);
  }

  // ---------------- speech recognition ----------------

  Future<void> _initSpeech() async {
    try {
      final ok = await _speech.initialize(
        onStatus: _onSpeechStatus,
        onError: _onSpeechError,
      );
      List<LocaleName> locales = [];
      LocaleName? sys;
      if (ok) {
        locales = await _speech.locales();
        sys = await _speech.systemLocale();
      }
      if (!mounted) return;
      setState(() {
        _speechReady = ok;
        _locales = locales;
        final saved = _localeId;
        if (saved == null || !locales.any((l) => l.localeId == saved)) {
          _localeId = sys?.localeId;
        }
      });
    } catch (e) {
      _setError('Speech recognition could not start: $e');
    }
  }

  Future<void> _pickLanguage() async {
    if (_locales.isEmpty) {
      await _initSpeech();
      if (_locales.isEmpty) {
        _setError('No speech languages were found. Check that the Google app '
            'is installed and updated, then try again.');
        return;
      }
    }
    if (!mounted) return;
    final chosen = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => LanguageSheet(locales: _locales, selected: _localeId),
    );
    if (chosen != null && mounted) {
      setState(() => _localeId = chosen);
      _savePrefs();
    }
  }

  String get _languageName {
    final id = _localeId;
    if (id == null) return 'Not selected';
    for (final l in _locales) {
      if (l.localeId == id) return l.name;
    }
    return id;
  }

  String _friendlyError(String m) {
    if (m.contains('network') || m.contains('server')) {
      return 'The speech engine could not reach the internet. Turn on '
          'mobile data or Wi-Fi, or download your language for offline use '
          '(Google app > Settings > Voice > Offline speech recognition).';
    }
    if (m.contains('language')) {
      return 'This language is not available for speech recognition. '
          'Pick another language or download it in your phone voice settings.';
    }
    if (m.contains('permission')) {
      return 'Microphone permission is missing. Allow it in phone Settings > '
          'Apps > Voice Notes > Permissions.';
    }
    if (m.contains('busy')) {
      return 'The microphone is busy. Close other apps that use it '
          '(calls, voice recorders) and try again.';
    }
    return 'Speech engine: $m';
  }

  void _onSpeechError(SpeechRecognitionError e) {
    final m = e.errorMsg;
    if (mounted) setState(() => _lastErr = m);
    if (m == 'error_no_match' || m == 'error_speech_timeout') return;
    _setError(_friendlyError(m));
  }

  void _onSpeechStatus(String s) {
    if (mounted) setState(() => _engine = s);
    // The phone's engine stops itself after a pause in speech.
    // While recording, start it again so text keeps flowing.
    if ((s == 'done' || s == 'notListening') &&
        _state == RecState.recording &&
        !_restarting) {
      _restarting = true;
      Future.delayed(const Duration(milliseconds: 500), () async {
        _restarting = false;
        if (_state == RecState.recording && mounted) {
          setState(() {
            _committed = _fullText;
            _partial = '';
          });
          await _listen();
        }
      });
    }
  }

  bool _alreadyCommitted(String words) {
    final c = _committed.trim().toLowerCase();
    final w = words.trim().toLowerCase();
    return w.isNotEmpty && c.endsWith(w);
  }

  void _onSpeech(SpeechRecognitionResult r) {
    if (!mounted) return;
    if (_state == RecState.idle && !_saving) return;
    final words = r.recognizedWords.trim();

    if (r.finalResult) {
      // The phone sometimes delivers the same final sentence twice.
      if (words.isEmpty || words == _lastFinal || _alreadyCommitted(words)) {
        setState(() => _partial = '');
        return;
      }
      _lastFinal = words;
      setState(() {
        _results++;
        _committed = [_committed, words].where((s) => s.isNotEmpty).join(' ');
        _partial = '';
      });
    } else {
      if (_alreadyCommitted(words)) return;
      setState(() {
        _results++;
        _partial = words;
      });
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _listen() async {
    if (!_speechReady) return;
    try {
      await _speech.listen(
        onResult: _onSpeech,
        localeId: _localeId,
        listenFor: const Duration(minutes: 30),
        pauseFor: const Duration(seconds: 10),
        onSoundLevelChange: (level) {
          if (_state != RecState.recording) return;
          // Use the engine's own level unless the recorder is working.
          if (_audioOn && _recLevel >= 20) return;
          final v = ((level + 2) / 12).clamp(0.0, 1.0).toDouble();
          _pushLevel(v, -60 + v * 55);
        },
        listenOptions: SpeechListenOptions(
          partialResults: true,
          cancelOnError: false,
          listenMode: ListenMode.dictation,
        ),
      );
    } catch (e) {
      _setError('Speech recognition error: $e');
    }
  }

  // ---------------- audio recording (optional) ----------------

  double _rms(Uint8List d) {
    final n = d.length ~/ 2;
    if (n == 0) return 0;
    final bd = ByteData.sublistView(d);
    double sum = 0;
    for (var i = 0; i < n; i++) {
      final v = bd.getInt16(i * 2, Endian.little);
      sum += v * v;
    }
    return sqrt(sum / n);
  }

  void _pushLevel(double v, double db) {
    _waves.add(v);
    if (_waves.length > _slots) _waves.removeAt(0);
    _db = db;
    _tick.value++;
  }

  void _onAudio(Uint8List raw) {
    if (_state != RecState.recording) return;
    final data = _isolate ? _iso.process(raw) : raw;
    final lvl = _rms(data);
    _recLevel = lvl;
    _peakAll = max(_peakAll, lvl);
    _all.add(data);
    final v = sqrt((lvl / 8000).clamp(0.0, 1.0)).toDouble();
    final db = lvl < 1 ? -90.0 : 20 * log(lvl / 32768) / ln10;
    _pushLevel(v, db);
  }

  void _resetAll() {
    _all.clear();
    _iso.reset();
    _waves.clear();
    _db = -90;
    _recLevel = 0;
    _peakAll = 0;
    _committed = '';
    _partial = '';
    _lastFinal = '';
    _sw
      ..stop()
      ..reset();
  }

  // ---------------- controls ----------------

  Future<void> _start() async {
    try {
      if (!_speechReady) await _initSpeech();
      if (_saveAudio) {
        final hasMic = await _rec.hasPermission();
        if (!hasMic) {
          _setError('Microphone permission was not granted. '
              'Allow it in phone Settings > Apps > Voice Notes > Permissions.');
          return;
        }
      } else if (!_speechReady) {
        _setError('Speech recognition is not available on this phone. '
            'Check that the Google app is installed and updated, then tap '
            'Retry. Or turn on "Also save audio" to record sound only.');
        return;
      }

      _resetAll();
      _audioOn = _saveAudio;
      setState(() {
        _state = RecState.recording;
        _error = null;
        _previewPath = null;
        _saved = null;
        _saveNote = null;
        _lastErr = '';
        _results = 0;
        _engine = 'starting';
      });
      AppErrors.last.value = null;
      _sw.start();
      _timer?.cancel();
      _timer = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (_state == RecState.recording) _tick.value++;
      });

      if (_audioOn) {
        try {
          final stream = await _rec.startStream(RecordConfig(
            encoder: AudioEncoder.pcm16bits,
            sampleRate: _rate,
            numChannels: 1,
            noiseSuppress: _isolate,
            echoCancel: _isolate,
            autoGain: _isolate,
          ));
          _sub = stream.listen(
            _onAudio,
            onError: (e) => _setError('Microphone error: $e'),
          );
        } catch (e) {
          _setError('Audio could not be recorded: $e');
        }
      }

      if (_speechReady) {
        await _listen();
      } else if (_audioOn) {
        _setError('Speech recognition is not available. '
            'Audio is still being recorded.');
      }
    } catch (e) {
      _setError('Could not start recording: $e');
      if (mounted) setState(() => _state = RecState.idle);
    }
  }

  Future<void> _pause() async {
    if (_state != RecState.recording) return;
    setState(() {
      _state = RecState.paused;
      _previewPath = null;
    });
    _sw.stop();
    try {
      await _speech.stop();
    } catch (_) {}
    if (_audioOn) {
      try {
        await _rec.pause();
      } catch (_) {}
    }
    if (mounted) {
      setState(() {
        _committed = _fullText;
        _partial = '';
      });
    }
  }

  Future<void> _resume() async {
    if (_state != RecState.paused) return;
    if (_audioOn) {
      try {
        await _rec.resume();
      } catch (_) {}
    }
    _sw.start();
    setState(() {
      _state = RecState.recording;
      _previewPath = null;
    });
    await _listen();
  }

  /// Lets the user hear everything recorded so far (audio mode only).
  Future<void> _listenSoFar() async {
    if (_all.length == 0) {
      _setError('No audio has been captured yet.');
      return;
    }
    try {
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/preview_${DateTime.now().millisecondsSinceEpoch}.wav';
      await File(path).writeAsBytes(AudioFiles.pcmToWav(_all.toBytes()));
      if (mounted) setState(() => _previewPath = path);
    } catch (e) {
      _setError('Could not prepare playback: $e');
    }
  }

  Future<void> _discard() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard this recording?'),
        content: const Text('Nothing will be saved.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep recording')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Discard')),
        ],
      ),
    );
    if (ok != true) return;
    _timer?.cancel();
    try {
      await _speech.cancel();
    } catch (_) {}
    await _sub?.cancel();
    if (_audioOn) {
      try {
        await _rec.stop();
      } catch (_) {}
    }
    if (mounted) {
      setState(() {
        _state = RecState.idle;
        _resetAll();
        _previewPath = null;
      });
    }
  }

  Future<void> _finish() async {
    if (_state == RecState.idle) return;
    setState(() {
      _state = RecState.idle;
      _saving = true;
      _previewPath = null;
    });
    _timer?.cancel();
    _sw.stop();
    try {
      try {
        await _speech.stop();
      } catch (_) {}
      // Give the engine a moment to deliver the last words.
      await Future.delayed(const Duration(milliseconds: 800));
      if (_audioOn) {
        try {
          await _sub?.cancel();
          await _rec.stop();
        } catch (_) {}
      }

      final text = _fullText.trim();
      String? audio;
      String? note;
      if (_audioOn) {
        if (_all.length > _rate && _peakAll >= 60) {
          audio = await AudioFiles.saveWav(_all.toBytes());
        } else {
          note = 'The audio could not be captured (the phone gave the '
              'microphone to speech recognition), so only the text was saved.';
        }
      } else {
        note = 'Audio was not saved. Turn on "Also save audio" on the home '
            'screen to keep recordings.';
      }

      if (text.isNotEmpty || audio != null) {
        final words = text.split(RegExp(r'\s+')).take(6).join(' ');
        final n = Note(
          title: words.isEmpty ? 'Voice note' : words,
          transcript: text,
          audioPath: audio,
          createdAt: DateTime.now(),
          locale: _localeId,
        );
        n.id = await NoteDb.instance.insert(n);
        if (mounted) {
          setState(() {
            _saved = n;
            _saveNote = note;
          });
        }
      } else {
        _setError('Nothing was captured. Speak clearly near the microphone, '
            'check the speech status line, and make sure the phone has '
            'internet or an offline language downloaded.');
      }
    } catch (e) {
      _setError('Could not save the note: $e');
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
          _committed = '';
          _partial = '';
        });
      }
    }
  }

  // ---------------- UI pieces ----------------

  Widget _errorBox() {
    return ValueListenableBuilder<String?>(
      valueListenable: AppErrors.last,
      builder: (context, globalError, _) {
        final msg = _error ?? globalError;
        if (msg == null) return const SizedBox.shrink();
        return Card(
          color: Theme.of(context).colorScheme.errorContainer,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: SelectableText('Problem: $msg')),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () {
                    AppErrors.last.value = null;
                    setState(() => _error = null);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _speechStatus() {
    if (_speechReady) {
      return const Row(children: [
        Icon(Icons.check_circle, size: 18, color: Colors.green),
        SizedBox(width: 8),
        Expanded(child: Text('Speech recognition ready.')),
      ]);
    }
    return Row(children: [
      const Icon(Icons.error_outline, size: 18, color: Colors.orange),
      const SizedBox(width: 8),
      const Expanded(child: Text('Speech recognition not available yet.')),
      TextButton(onPressed: _initSpeech, child: const Text('Retry')),
    ]);
  }

  Widget _idleTop() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            _speechStatus(),
            const SizedBox(height: 4),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.language),
              title: const Text('Speaking language'),
              subtitle: Text(_languageName),
              trailing: const Icon(Icons.arrow_drop_down),
              onTap: _pickLanguage,
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Tap to search and choose any language your phone supports. '
                'For offline use, download it in your phone voice settings.',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Also save audio'),
              subtitle: const Text(
                  'Lets you play the recording back. On many phones this '
                  'blocks live text, so leave it off for reliable text.'),
              value: _saveAudio,
              onChanged: (v) {
                setState(() => _saveAudio = v);
                _savePrefs();
              },
            ),
            if (_saveAudio)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Voice isolation'),
                subtitle:
                    const Text('Cleans background noise in the saved audio'),
                value: _isolate,
                onChanged: (v) {
                  setState(() => _isolate = v);
                  _savePrefs();
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _meterCard() {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: ValueListenableBuilder<int>(
          valueListenable: _tick,
          builder: (context, _, __) {
            final paused = _state == RecState.paused;
            String quality;
            Color qColor;
            if (paused) {
              quality = 'Paused';
              qColor = scheme.outline;
            } else if (_db < -45) {
              quality = 'Too quiet';
              qColor = Colors.orange;
            } else if (_db > -8) {
              quality = 'Too loud';
              qColor = Colors.red;
            } else {
              quality = 'Good level';
              qColor = Colors.green;
            }
            return Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(children: [
                      Icon(Icons.fiber_manual_record,
                          size: 14,
                          color: paused ? scheme.outline : Colors.red),
                      const SizedBox(width: 8),
                      Text(
                        fmtDuration(_sw.elapsed),
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                    ]),
                    Text(quality,
                        style: TextStyle(
                            color: qColor, fontWeight: FontWeight.w600)),
                  ],
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 72,
                  width: double.infinity,
                  child: CustomPaint(
                    painter: WavePainter(
                        List<double>.of(_waves), _slots, scheme.primary),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('${_db.round()} dB',
                        style: Theme.of(context).textTheme.labelMedium),
                    Text(
                        _audioOn
                            ? '${(_all.length / 1024 / 1024).toStringAsFixed(1)} MB'
                            : 'Live text only',
                        style: Theme.of(context).textTheme.labelMedium),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _transcriptArea() {
    if (_saving) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text('Saving...'),
          ],
        ),
      );
    }

    if (_state == RecState.idle && _saved != null) {
      final n = _saved!;
      return ListView(
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    const Icon(Icons.check_circle, color: Colors.green),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('Saved: ${n.title}',
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ]),
                  const SizedBox(height: 12),
                  if (n.audioPath != null)
                    PlayerBar(key: ValueKey(n.audioPath), path: n.audioPath!),
                  if (_saveNote != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(_saveNote!,
                          style: Theme.of(context).textTheme.bodySmall),
                    ),
                  const SizedBox(height: 8),
                  SelectableText(n.transcript.isEmpty
                      ? '(No speech was detected)'
                      : n.transcript),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    children: [
                      FilledButton.icon(
                        icon: const Icon(Icons.edit),
                        label: const Text('Edit, translate, export'),
                        onPressed: () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => EditorScreen(note: n)),
                          );
                          if (mounted) setState(() {});
                        },
                      ),
                      OutlinedButton(
                        onPressed: () => setState(() {
                          _saved = null;
                          _saveNote = null;
                        }),
                        child: const Text('Done'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    if (_state == RecState.idle) {
      return const Center(child: Text('Tap the mic to start recording'));
    }

    final text = _fullText;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Live transcript', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          'Speech engine: $_engine  |  results: $_results'
          '${_lastErr.isEmpty ? '' : '  |  last error: $_lastErr'}',
          style: Theme.of(context).textTheme.labelSmall,
        ),
        const SizedBox(height: 8),
        if (_state == RecState.paused && _previewPath != null)
          PlayerBar(key: ValueKey(_previewPath), path: _previewPath!),
        Expanded(
          child: SingleChildScrollView(
            controller: _scroll,
            child: SizedBox(
              width: double.infinity,
              child: Text(
                text.isEmpty ? 'Start speaking. Your words appear here...' : text,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _btn(IconData icon, String label, VoidCallback? onTap,
      {required String tag, bool big = false, bool small = false}) {
    final Widget b = big
        ? FloatingActionButton.large(
            heroTag: tag, onPressed: onTap, child: Icon(icon))
        : small
            ? FloatingActionButton.small(
                heroTag: tag, onPressed: onTap, child: Icon(icon))
            : FloatingActionButton(
                heroTag: tag, onPressed: onTap, child: Icon(icon));
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [b, const SizedBox(height: 6), Text(label)],
    );
  }

  Widget _controls() {
    if (_saving) return const SizedBox(height: 96);
    switch (_state) {
      case RecState.idle:
        return _btn(Icons.mic, 'Record', _start, tag: 'main', big: true);
      case RecState.recording:
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _btn(Icons.delete_outline, 'Discard', _discard,
                tag: 'discard', small: true),
            _btn(Icons.pause, 'Pause', _pause, tag: 'main', big: true),
            _btn(Icons.stop, 'Save', _finish, tag: 'save'),
          ],
        );
      case RecState.paused:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_audioOn)
              FilledButton.tonalIcon(
                onPressed: _listenSoFar,
                icon: const Icon(Icons.headphones),
                label: const Text('Listen so far'),
              ),
            if (_audioOn) const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _btn(Icons.delete_outline, 'Discard', _discard,
                    tag: 'discard', small: true),
                _btn(Icons.mic, 'Resume', _resume, tag: 'main', big: true),
                _btn(Icons.stop, 'Save', _finish, tag: 'save'),
              ],
            ),
          ],
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final idle = _state == RecState.idle;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Voice Notes'),
        actions: [
          IconButton(
            icon: const Icon(Icons.library_books),
            tooltip: 'My notes',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const NotesScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            _errorBox(),
            if (idle && !_saving && _saved == null) _idleTop(),
            if (!idle) _meterCard(),
            if (!idle)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Keep the app open and the screen on while recording.',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
            const SizedBox(height: 8),
            Expanded(child: _transcriptArea()),
            const SizedBox(height: 12),
            _controls(),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

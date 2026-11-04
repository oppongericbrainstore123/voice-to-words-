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
import 'package:sqflite/sqflite.dart';
import 'package:whisper_flutter_new/whisper_flutter_new.dart';

// ============================================================
// APP START + THEME + ERROR CATCHING
// ============================================================

class AppErrors {
  static final ValueNotifier<String?> last = ValueNotifier(null);
  static void report(String message) => last.value = message;
}

void main() {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    FlutterError.onError = (d) => AppErrors.report(d.exceptionAsString());
    await AppSettings.load();
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
// WHISPER (speech to text)
// ============================================================

class WhisperService {
  WhisperService._();
  static final WhisperService instance = WhisperService._();

  // "tiny" is light and fast on phones. Switch to WhisperModel.base
  // later for better accuracy on a faster phone.
  final Whisper _whisper = Whisper(model: WhisperModel.tiny);

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

  static String clean(String t) => t
      .replaceAll(RegExp(r'\[[^\]]*\]|\([^)]*\)'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  Future<String> transcribePcm(Uint8List pcm, {String language = 'auto'}) async {
    final dir = await getTemporaryDirectory();
    final f = File(
        '${dir.path}/chunk_${DateTime.now().microsecondsSinceEpoch}.wav');
    await f.writeAsBytes(pcmToWav(pcm));
    try {
      final r = await _whisper.transcribe(
        transcribeRequest: TranscribeRequest(
          audio: f.path,
          language: language,
          isTranslate: false,
          isNoTimestamps: true,
          splitOnWord: false,
        ),
      );
      return clean(r.text);
    } finally {
      if (await f.exists()) await f.delete();
    }
  }

  Future<String> saveWav(Uint8List pcm) async {
    final dir = await getApplicationDocumentsDirectory();
    final path =
        '${dir.path}/note_${DateTime.now().millisecondsSinceEpoch}.wav';
    await File(path).writeAsBytes(pcmToWav(pcm));
    return path;
  }
}

// ============================================================
// VOICE ISOLATION (optional noise filter)
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

class TranslationService {
  static final OnDeviceTranslatorModelManager _manager =
      OnDeviceTranslatorModelManager();

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

  static Future<String> translate(
    String text,
    TranslateLanguage from,
    TranslateLanguage to,
  ) async {
    for (final l in [from, to]) {
      if (!await _manager.isModelDownloaded(l.bcpCode)) {
        await _manager.downloadModel(l.bcpCode, isWifiRequired: false);
      }
    }
    final translator =
        OnDeviceTranslator(sourceLanguage: from, targetLanguage: to);
    try {
      return await translator.translateText(text);
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
    final files = <String, String>{
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
    final list = <Map<String, Object?>>[];

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
  final AudioPlayer _player = AudioPlayer();
  List<Note> _notes = [];
  String _query = '';
  int? _playingId;

  @override
  void initState() {
    super.initState();
    _load();
    _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _playingId = null);
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final notes = await NoteDb.instance.all(query: _query);
    if (mounted) setState(() => _notes = notes);
  }

  Future<void> _togglePlay(Note n) async {
    if (_playingId == n.id) {
      await _player.stop();
      setState(() => _playingId = null);
    } else {
      await _player.play(DeviceFileSource(n.audioPath!));
      setState(() => _playingId = n.id);
    }
  }

  Future<void> _delete(Note n) async {
    if (_playingId == n.id) await _player.stop();
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
                  leading: n.audioPath == null
                      ? const Icon(Icons.notes)
                      : IconButton(
                          icon: Icon(_playingId == n.id
                              ? Icons.stop_circle
                              : Icons.play_circle),
                          onPressed: () => _togglePlay(n),
                        ),
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
// EDITOR SCREEN (edit, translate, export)
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
    setState(() => _busy = true);
    try {
      final result =
          await TranslationService.translate(_text.text, _from, _to);
      _translation.text = result;
      await _save(quiet: true);
    } catch (e) {
      _msg('Translation failed. The first use of a language needs internet '
          'to download its pack.');
    } finally {
      if (mounted) setState(() => _busy = false);
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
              label: Text(_busy ? 'Translating...' : 'Translate'),
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
// RECORDER SCREEN (home)
// ============================================================

enum RecState { idle, recording, paused }

class RecorderScreen extends StatefulWidget {
  const RecorderScreen({super.key});

  @override
  State<RecorderScreen> createState() => _RecorderScreenState();
}

class _RecorderScreenState extends State<RecorderScreen> {
  static const int _rate = 16000;
  static const double _minSecs = 4;
  static const double _maxSecs = 12;
  static const double _silence = 500;

  final AudioRecorder _rec = AudioRecorder();
  final VoiceIsolator _iso = VoiceIsolator();
  StreamSubscription<Uint8List>? _sub;
  final BytesBuilder _all = BytesBuilder(copy: false);
  final BytesBuilder _chunk = BytesBuilder(copy: false);
  int _chunkBytes = 0;
  Future<void> _queue = Future.value();

  RecState _state = RecState.idle;
  bool _saving = false;
  bool _isolate = false; // off by default: it can mute quiet voices
  String _lang = 'auto';
  String _text = '';
  int _pending = 0;
  double _level = 0;
  String? _error;

  @override
  void dispose() {
    _sub?.cancel();
    _rec.dispose();
    super.dispose();
  }

  void _setError(String m) {
    if (mounted) setState(() => _error = m);
  }

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

  void _onAudio(Uint8List raw) {
    if (_state != RecState.recording) return;
    final data = _isolate ? _iso.process(raw) : raw;
    final lvl = _rms(data);
    _all.add(data);
    _chunk.add(data);
    _chunkBytes += data.length;
    if (mounted) setState(() => _level = lvl);
    final secs = _chunkBytes / (_rate * 2);
    if (secs >= _minSecs && (secs >= _maxSecs || lvl < _silence)) {
      _flush();
    }
  }

  void _flush() {
    if (_chunkBytes < _rate * 2 * 0.3) return;
    final bytes = _chunk.takeBytes();
    _chunkBytes = 0;
    if (mounted) setState(() => _pending++);
    _queue = _queue.then((_) async {
      try {
        final t = await WhisperService.instance
            .transcribePcm(bytes, language: _lang);
        if (t.isNotEmpty && mounted) {
          setState(() => _text = _text.isEmpty ? t : '$_text $t');
        }
      } catch (e) {
        _setError('Transcription error: $e');
      } finally {
        if (mounted) setState(() => _pending--);
      }
    });
  }

  Future<void> _start() async {
    try {
      if (!await _rec.hasPermission()) {
        _setError('Microphone permission was not granted. '
            'Allow it in phone Settings > Apps > Voice Notes > Permissions.');
        return;
      }
      _all.clear();
      _chunk.clear();
      _chunkBytes = 0;
      _iso.reset();
      setState(() {
        _state = RecState.recording;
        _text = '';
        _pending = 0;
        _level = 0;
        _error = null;
      });
      AppErrors.last.value = null;
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
      _setError('Could not start recording: $e');
      if (mounted) setState(() => _state = RecState.idle);
    }
  }

  Future<void> _pause() async {
    if (_state != RecState.recording) return;
    setState(() => _state = RecState.paused);
    try {
      await _rec.pause();
    } catch (_) {}
    _flush();
  }

  Future<void> _resume() async {
    if (_state != RecState.paused) return;
    try {
      await _rec.resume();
    } catch (_) {}
    setState(() => _state = RecState.recording);
  }

  Future<void> _finish() async {
    if (_state == RecState.idle) return;
    setState(() {
      _state = RecState.idle;
      _saving = true;
      _level = 0;
    });
    try {
      await _sub?.cancel();
      await _rec.stop();
      _flush();
      await _queue;

      final text = _text.trim();
      String? audio;
      if (_all.length > 0) {
        audio = await WhisperService.instance.saveWav(_all.toBytes());
      }
      if (text.isNotEmpty || audio != null) {
        final words = text.split(RegExp(r'\s+')).take(6).join(' ');
        await NoteDb.instance.insert(Note(
          title: words.isEmpty ? 'Voice note' : words,
          transcript: text,
          audioPath: audio,
          createdAt: DateTime.now(),
          locale: _lang == 'auto' ? null : _lang,
        ));
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('Note saved')));
        }
      }
    } catch (e) {
      _setError('Could not save the note: $e');
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
          _text = '';
        });
      }
    }
  }

  String get _statusLabel {
    if (_saving) return 'Finishing transcription...';
    switch (_state) {
      case RecState.idle:
        return 'Ready. The first transcription downloads the speech model '
            '(internet needed once).';
      case RecState.recording:
        return _pending > 0
            ? 'Recording... transcribing (first time is slow: downloads model)'
            : 'Recording...';
      case RecState.paused:
        return 'Paused. Tap the mic to continue, or stop to save.';
    }
  }

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

  Widget _settings() {
    return Column(
      children: [
        DropdownButtonFormField<String>(
          value: _lang,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Speaking language'),
          items: [
            const DropdownMenuItem(value: 'auto', child: Text('Auto-detect')),
            ...TranslationService.languages.map((l) => DropdownMenuItem(
                  value: l.bcpCode,
                  child: Text(TranslationService.label(l)),
                )),
          ],
          onChanged: (v) => setState(() => _lang = v ?? 'auto'),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Voice isolation'),
          subtitle: const Text('Filters background noise (may cut quiet voices)'),
          value: _isolate,
          onChanged: (v) => setState(() => _isolate = v),
        ),
      ],
    );
  }

  Widget _micMeter() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Mic level'),
        const SizedBox(height: 4),
        LinearProgressIndicator(
          value: (_level / 4000).clamp(0.0, 1.0).toDouble(),
          minHeight: 8,
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _controls() {
    if (_saving) return const CircularProgressIndicator();
    switch (_state) {
      case RecState.idle:
        return FloatingActionButton.large(
          heroTag: 'start',
          onPressed: _start,
          child: const Icon(Icons.mic),
        );
      case RecState.recording:
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            FloatingActionButton.large(
              heroTag: 'pause',
              onPressed: _pause,
              child: const Icon(Icons.pause),
            ),
            const SizedBox(width: 24),
            FloatingActionButton(
              heroTag: 'save',
              onPressed: _finish,
              child: const Icon(Icons.stop),
            ),
          ],
        );
      case RecState.paused:
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            FloatingActionButton.large(
              heroTag: 'resume',
              onPressed: _resume,
              child: const Icon(Icons.mic),
            ),
            const SizedBox(width: 24),
            FloatingActionButton(
              heroTag: 'save',
              onPressed: _finish,
              child: const Icon(Icons.stop),
            ),
          ],
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Voice Notes'),
        actions: [
          IconButton(
            icon: const Icon(Icons.library_books),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const NotesScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
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
            if (_state == RecState.idle && !_saving) _settings(),
            if (_state == RecState.recording) _micMeter(),
            Text(_statusLabel, style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 12),
            Expanded(
              child: SingleChildScrollView(
                child: Text(
                  _text.isEmpty ? 'Tap the mic and start speaking...' : _text,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
            ),
            const SizedBox(height: 16),
            _controls(),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

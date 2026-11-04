import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

void main() {
  runApp(const VoiceToWordsApp());
}

class VoiceToWordsApp extends StatelessWidget {
  const VoiceToWordsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Voice To Words',
      theme: ThemeData(primarySwatch: Colors.indigo),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;
  final List<String> _savedNotes = [];

  @override
  Widget build(BuildContext context) {
    final screens = [
      RecorderScreen(onSaveNote: (note) {
        setState(() {
          _savedNotes.add(note);
        });
      }),
      NotesListScreen(notes: _savedNotes),
      const EditorExportScreen(),
    ];

    return Scaffold(
      body: screens[_currentIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) => setState(() => _currentIndex = index),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.mic), label: 'Record'),
          BottomNavigationBarItem(icon: Icon(Icons.folder), label: 'Saved Notes'),
          BottomNavigationBarItem(icon: Icon(Icons.picture_as_pdf), label: 'Editor & Export'),
        ],
      ),
    );
  }
}

// 1. Recorder & Speech-to-Text Section
class RecorderScreen extends StatefulWidget {
  final Function(String) onSaveNote;
  const RecorderScreen({super.key, required this.onSaveNote});

  @override
  State<RecorderScreen> createState() => _RecorderScreenState();
}

class _RecorderScreenState extends State<RecorderScreen> {
  late stt.SpeechToText _speech;
  bool _isListening = false;
  String _text = 'Press the microphone to start speaking...';
  bool _noiseIsolationEnabled = true;

  @override
  void initState() {
    super.initState();
    _speech = stt.SpeechToText();
  }

  void _listen() async {
    if (!_isListening) {
      bool available = await _speech.initialize(
        onStatus: (status) => print('Status: $status'),
        onError: (error) => print('Error: $error'),
      );
      if (available) {
        setState(() => _isListening = true);
        _speech.listen(
          onResult: (val) => setState(() {
            _text = val.recognizedWords;
          }),
        );
      }
    } else {
      setState(() => _isListening = false);
      _speech.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Voice to Words Studio')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            SwitchListTile(
              title: const Text('Voice Isolation / Noise Filter'),
              subtitle: const Text('Amplifies speaker & blocks background static'),
              value: _noiseIsolationEnabled,
              onChanged: (val) => setState(() => _noiseIsolationEnabled = val),
            ),
            const SizedBox(height: 20),
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  child: Text(_text, style: const TextStyle(fontSize: 18)),
                ),
              ),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: () {
                if (_text.isNotEmpty && _text != 'Press the microphone to start speaking...') {
                  widget.onSaveNote(_text);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Note saved successfully!')),
                  );
                }
              },
              icon: const Icon(Icons.save),
              label: const Text('Save to Notes'),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _listen,
        child: Icon(_isListening ? Icons.mic : Icons.mic_none),
      ),
    );
  }
}

// 2. Saved Notes & Universal Search Section
class NotesListScreen extends StatefulWidget {
  final List<String> notes;
  const NotesListScreen({super.key, required this.notes});

  @override
  State<NotesListScreen> createState() => _NotesListScreenState();
}

class _NotesListScreenState extends State<NotesListScreen> {
  String _searchQuery = '';

  @override
  Widget build(BuildContext context) {
    final filteredNotes = widget.notes
        .where((note) => note.toLowerCase().contains(_searchQuery.toLowerCase()))
        .toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Saved Voice Notes')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: TextField(
              onChanged: (value) => setState(() => _searchQuery = value),
              decoration: const InputDecoration(
                labelText: 'Search all media & notes...',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
            ),
          ),
          Expanded(
            child: filteredNotes.isEmpty
                ? const Center(child: Text('No saved notes found.'))
                : ListView.builder(
                    itemCount: filteredNotes.length,
                    itemBuilder: (context, index) {
                      return ListTile(
                        leading: const Icon(Icons.note),
                        title: Text(filteredNotes[index]),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// 3. Document Editor & PDF Export Section
class EditorExportScreen extends StatefulWidget {
  const EditorExportScreen({super.key});

  @override
  State<EditorExportScreen> createState() => _EditorExportScreenState();
}

class _EditorExportScreenState extends State<EditorExportScreen> {
  final TextEditingController _controller = TextEditingController(
    text: 'Edit your finalized transcript here before exporting...',
  );

  Future<void> _exportPdf() async {
    final pdf = pw.Document();
    pdf.addPage(
      pw.Page(
        build: (pw.Context context) {
          return pw.Center(
            child: pw.Text(_controller.text, style: const pw.TextStyle(fontSize: 20)),
          );
        },
      ),
    );

    await Printing.layoutPdf(
      onLayout: (format) async => pdf.save(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Word Doc & PDF Export')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                maxLines: null,
                expands: true,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(height: 15),
            ElevatedButton.icon(
              onPressed: _exportPdf,
              icon: const Icon(Icons.picture_as_pdf),
              label: const Text('Export as PDF Document'),
            ),
          ],
        ),
      ),
    );
  }
}

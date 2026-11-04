// ============================================================
// RECORDER SCREEN (home)
// ============================================================

enum RecState { idle, recording, paused, preview }

class RecorderScreen extends StatefulWidget {
  const RecorderScreen({super.key});

  @override
  State<RecorderScreen> createState() => _RecorderScreenState();
}

class _RecorderScreenState extends State<RecorderScreen> {
  static const int _rate = 16000;
  // Shorter chunks (e.g., 2 to 4 seconds) allow faster simultaneous text updates
  static const double _minSecs = 2.0;
  static const double _maxSecs = 5.0;
  static const double _silence = 400;

  final AudioRecorder _rec = AudioRecorder();
  final AudioPlayer _previewPlayer = AudioPlayer();
  final VoiceIsolator _iso = VoiceIsolator();
  StreamSubscription<Uint8List>? _sub;
  StreamSubscription<void>? _playerSub;
  
  final BytesBuilder _all = BytesBuilder(copy: false);
  final BytesBuilder _chunk = BytesBuilder(copy: false);
  int _chunkBytes = 0;
  Future<void> _queue = Future.value();

  Timer? _timer;
  int _elapsedSeconds = 0;

  RecState _state = RecState.idle;
  bool _saving = false;
  bool _isPlayingPreview = false;
  bool _isolate = false;
  String _lang = 'auto';
  String _text = '';
  int _pending = 0;
  double _level = 0;
  String? _error;
  String? _tempAudioPath;

  @override
  void initState() {
    super.initState();
    _playerSub = _previewPlayer.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _isPlayingPreview = false);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _sub?.cancel();
    _playerSub?.cancel();
    _rec.dispose();
    _previewPlayer.dispose();
    super.dispose();
  }

  void _setError(String m) {
    if (mounted) setState(() => _error = m);
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _state == RecState.recording) {
        setState(() => _elapsedSeconds++);
      }
    });
  }

  String _formatTime(int seconds) {
    final mins = (seconds ~/ 60).toString().padLeft(2, '0');
    final secs = (seconds % 60).toString().padLeft(2, '0');
    return '$mins:$secs';
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
    // Automatically flushes and translates chunks simultaneously as you speak
    if (secs >= _minSecs && (secs >= _maxSecs || lvl < _silence)) {
      _flush();
    }
  }

  void _flush() {
    if (_chunkBytes < _rate * 2 * 0.2) return;
    final bytes = _chunk.takeBytes();
    _chunkBytes = 0;
    if (mounted) setState(() => _pending++);
    
    _queue = _queue.then((_) async {
      try {
        final t = await WhisperService.instance
            .transcribePcm(bytes, language: _lang);
        if (t.isNotEmpty && mounted) {
          setState(() {
            _text = _text.isEmpty ? t : '$_text $t';
          });
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
      await _previewPlayer.stop();
      _all.clear();
      _chunk.clear();
      _chunkBytes = 0;
      _elapsedSeconds = 0;
      _iso.reset();
      setState(() {
        _state = RecState.recording;
        _text = '';
        _pending = 0;
        _level = 0;
        _error = null;
        _tempAudioPath = null;
        _isPlayingPreview = false;
      });
      AppErrors.last.value = null;
      _startTimer();
      
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
    _timer?.cancel();
    setState(() => _state = RecState.paused);
    try {
      await _rec.pause();
    } catch (_) {}
    _flush(); // Flush remaining speech buffer immediately
  }

  Future<void> _resume() async {
    if (_state != RecState.paused) return;
    _startTimer();
    try {
      await _rec.resume();
    } catch (_) {}
    setState(() => _state = RecState.recording);
  }

  Future<void> _stopToPreview() async {
    if (_state == RecState.idle || _state == RecState.preview) return;
    _timer?.cancel();
    setState(() {
      _saving = true;
      _level = 0;
    });
    try {
      await _sub?.cancel();
      await _rec.stop();
      _flush();
      await _queue; // Ensure last background translation chunks finish processing

      if (_all.length > 0) {
        _tempAudioPath = await WhisperService.instance.saveWav(_all.toBytes());
      }
      setState(() {
        _state = RecState.preview;
        _saving = false;
      });
    } catch (e) {
      _setError('Could not process recording: $e');
      setState(() {
        _state = RecState.idle;
        _saving = false;
      });
    }
  }

  Future<void> _togglePlaybackPreview() async {
    if (_tempAudioPath == null) return;
    if (_isPlayingPreview) {
      await _previewPlayer.stop();
      setState(() => _isPlayingPreview = false);
    } else {
      await _previewPlayer.play(DeviceFileSource(_tempAudioPath!));
      setState(() => _isPlayingPreview = true);
    }
  }

  Future<void> _saveNote() async {
    setState(() => _saving = true);
    try {
      await _previewPlayer.stop();
      final text = _text.trim();
      if (text.isNotEmpty || _tempAudioPath != null) {
        final words = text.split(RegExp(r'\s+')).take(6).join(' ');
        await NoteDb.instance.insert(Note(
          title: words.isEmpty ? 'Voice note' : words,
          transcript: text,
          audioPath: _tempAudioPath,
          createdAt: DateTime.now(),
          locale: _lang == 'auto' ? null : _lang,
        ));
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('Note saved successfully')));
        }
      }
    } catch (e) {
      _setError('Could not save note: $e');
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
          _state = RecState.idle;
          _text = '';
          _tempAudioPath = null;
          _elapsedSeconds = 0;
        });
      }
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

  Widget _recordingReadingsDisplay() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: _state == RecState.recording ? Colors.red : Colors.orange,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _state == RecState.recording ? 'SIMULTANEOUS TRANSCRIPTION' : 'PAUSED',
                    style: const TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.1),
                  ),
                ],
              ),
              Text(
                _formatTime(_elapsedSeconds),
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Align(
            alignment: Alignment.centerLeft,
            child: Text('Live Mic Level Readings', style: TextStyle(fontSize: 12, color: Colors.grey)),
          ),
          const SizedBox(height: 4),
          LinearProgressIndicator(
            value: (_level / 4000).clamp(0.0, 1.0).toDouble(),
            minHeight: 10,
            borderRadius: BorderRadius.circular(5),
          ),
        ],
      ),
    );
  }

  Widget _controls() {
    if (_saving) return const CircularProgressIndicator();
    switch (_state) {
      case RecState.idle:
        return FloatingActionButton.large(
          heroTag: 'start',
          onPressed: _start,
          child: const Icon(Icons.mic, size: 36),
        );
      case RecState.recording:
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            FloatingActionButton(
              heroTag: 'pause',
              onPressed: _pause,
              child: const Icon(Icons.pause),
            ),
            const SizedBox(width: 24),
            FloatingActionButton.large(
              heroTag: 'stop_rec',
              onPressed: _stopToPreview,
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
              child: const Icon(Icons.stop, size: 36),
            ),
          ],
        );
      case RecState.paused:
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            FloatingActionButton(
              heroTag: 'resume',
              onPressed: _resume,
              child: const Icon(Icons.mic),
            ),
            const SizedBox(width: 24),
            FloatingActionButton.large(
              heroTag: 'stop_paused',
              onPressed: _stopToPreview,
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
              child: const Icon(Icons.stop, size: 36),
            ),
          ],
        );
      case RecState.preview:
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ElevatedButton.icon(
              onPressed: _togglePlaybackPreview,
              icon: Icon(_isPlayingPreview ? Icons.pause_circle : Icons.play_circle),
              label: Text(_isPlayingPreview ? 'Pause Audio' : 'Play Recording'),
            ),
            const SizedBox(width: 16),
            FilledButton.icon(
              onPressed: _saveNote,
              icon: const Icon(Icons.save),
              label: const Text('Save Note'),
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
            if (_state == RecState.recording || _state == RecState.paused) ...[
              _recordingReadingsDisplay(),
              const SizedBox(height: 16),
            ],
            if (_state == RecState.preview) ...[
              Card(
                color: Theme.of(context).colorScheme.primaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      const Icon(Icons.check_circle),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Recording finished (${_formatTime(_elapsedSeconds)}). Preview or save below!',
                          style: TextStyle(color: Theme.of(context).colorScheme.onPrimaryContainer),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
            Text(_statusLabel, style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 12),
            Expanded(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    _text.isEmpty ? 'Speak and watch your words appear simultaneously here...' : _text,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
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

  String get _statusLabel {
    if (_saving) return 'Processing final chunks...';
    switch (_state) {
      case RecState.idle:
        return 'Ready. The first transcription downloads the speech model (internet needed once).';
      case RecState.recording:
        return _pending > 0
            ? 'Transcribing speech chunks live...'
            : 'Listening and converting simultaneously...';
      case RecState.paused:
        return 'Paused. Tap resume to continue or stop to preview.';
      case RecState.preview:
        return 'Review your simultaneous transcript and audio before saving.';
    }
  }
}

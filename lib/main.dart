import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:app_links/app_links.dart';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

const base = 'https://music.thesync.my.id';
const webClientId = String.fromEnvironment('GOOGLE_WEB_CLIENT_ID');
const cBg = Color(0xFF050816), cPanel = Color(0xFF0A1130), cCard = Color(0xFF0F1A45);
const cAc = Color(0xFF3B82F6), cAc2 = Color(0xFF38BDF8), cMu = Color(0xFF8FA0CC);
const langs = {'': 'Off', 'id': 'Indonesian', 'en': 'English', 'ms': 'Malay', 'ja': 'Japanese', 'ko': 'Korean', 'zh-CN': 'Chinese', 'es': 'Spanish', 'fr': 'French', 'de': 'German', 'ar': 'Arabic', 'hi': 'Hindi', 'th': 'Thai'};
const shelfQ = ['Top hits', 'Indonesia pop', 'Chill vibes', 'Workout'];
final mk = GlobalKey<ScaffoldMessengerState>();
void toast(String m) => mk.currentState?.showSnackBar(SnackBar(content: Text(m)));
String enc(String s) => Uri.encodeComponent(s);

class Api {
  static String? token;
  static VoidCallback? onExpired;
  static String get cookie => '__Secure-next-auth.session-token=$token';
  static Map<String, String> get h => {'Cookie': cookie, 'Content-Type': 'application/json'};
  static String img(String u) => '$base/api/img?u=${enc(u)}';
  static dynamic _out(http.Response r) {
    if (r.statusCode == 401) { onExpired?.call(); throw 'Session expired'; }
    return jsonDecode(utf8.decode(r.bodyBytes));
  }
  static Future<dynamic> get(String p) async => _out(await http.get(Uri.parse('$base$p'), headers: h).timeout(const Duration(seconds: 60)));
  static Future<dynamic> post(String p, Object b) async => _out(await http.post(Uri.parse('$base$p'), headers: h, body: jsonEncode(b)).timeout(const Duration(seconds: 60)));
}

class Track {
  final String id, title, artist, album, cover;
  final int duration;
  final String? audio;
  Track(this.id, this.title, this.artist, this.album, this.cover, this.duration, this.audio);
  factory Track.fromJson(Map j) => Track('${j['id']}', '${j['title']}', '${j['artist'] ?? ''}', '${j['album'] ?? ''}', '${j['cover'] ?? ''}', ((j['duration'] ?? 0) as num).toInt(), j['audio'] as String?);
  Map<String, dynamic> toJson() => {'id': id, 'title': title, 'artist': artist, 'album': album, 'cover': cover, 'duration': duration, 'audio': audio};
}

class Handler extends BaseAudioHandler with SeekHandler {
  final p = AudioPlayer();
  VoidCallback? onNext, onPrev, onDone;
  Handler() {
    p.playbackEventStream.listen((e) => playbackState.add(PlaybackState(
          controls: [MediaControl.skipToPrevious, p.playing ? MediaControl.pause : MediaControl.play, MediaControl.skipToNext],
          systemActions: const {MediaAction.seek},
          androidCompactActionIndices: const [0, 1, 2],
          processingState: const {
            ProcessingState.idle: AudioProcessingState.idle,
            ProcessingState.loading: AudioProcessingState.loading,
            ProcessingState.buffering: AudioProcessingState.buffering,
            ProcessingState.ready: AudioProcessingState.ready,
            ProcessingState.completed: AudioProcessingState.completed,
          }[p.processingState]!,
          playing: p.playing, updatePosition: p.position, bufferedPosition: p.bufferedPosition, speed: p.speed,
        )));
    p.processingStateStream.listen((s) { if (s == ProcessingState.completed) onDone?.call(); });
  }
  @override Future<void> play() => p.play();
  @override Future<void> pause() => p.pause();
  @override Future<void> seek(Duration d) => p.seek(d);
  @override Future<void> stop() async { await p.stop(); await super.stop(); }
  @override Future<void> skipToNext() async => onNext?.call();
  @override Future<void> skipToPrevious() async => onPrev?.call();
}

late Handler handler;
final S = Store();

class LL { final double t; final String x; LL(this.t, this.x); }

class Store extends ChangeNotifier {
  late SharedPreferences sp;
  bool ready = false, shuffle = false, repeat = false, loading = false, lyLoading = false;
  String? token;
  Map<String, dynamic>? user;
  List<Track> queue = [], liked = [], recent = [];
  List<LL> lines = [];
  List<String> plain = [];
  List<String>? tr;
  String tl = '';
  int index = -1, _tick = 0;
  Uri? pending;
  Track? get cur => index >= 0 && index < queue.length ? queue[index] : null;
  bool isLiked(String id) => liked.any((t) => t.id == id);

  Future<void> init() async {
    sp = await SharedPreferences.getInstance();
    token = sp.getString('token'); tl = sp.getString('tl') ?? '';
    final u = sp.getString('user');
    if (u != null) user = jsonDecode(u);
    Api.token = token;
    Api.onExpired = () { token = null; Api.token = null; sp.remove('token'); notifyListeners(); };
    handler.onNext = next; handler.onPrev = prev;
    handler.onDone = () { if (repeat) { handler.p.seek(Duration.zero); handler.p.play(); } else { next(); } };
    try {
      final al = AppLinks();
      al.uriLinkStream.listen(open, onError: (_) {});
      final first = await al.getInitialLink().timeout(const Duration(seconds: 2), onTimeout: () => null);
      if (first != null) pending = first;
    } catch (_) {}
    ready = true; notifyListeners();
    if (token != null) { await loadLib(); if (pending != null) { final p = pending!; pending = null; open(p); } }
  }

  Future<void> open(Uri u) async {
    final t = u.queryParameters['t'];
    if (t == null) return;
    if (token == null) { pending = u; return; }
    try {
      final r = await Api.get('/api/search?type=track&q=${enc('$t ${u.queryParameters['a'] ?? ''}')}');
      final l = (r['results'] as List).map((e) => Track.fromJson(e)).toList();
      if (l.isEmpty) return toast('Song not found');
      final k = l.indexWhere((x) => x.title.toLowerCase() == t.toLowerCase());
      play(l, k < 0 ? 0 : k);
    } catch (_) { toast('Could not open shared song'); }
  }

  Future<void> login() async {
    try {
      final acc = await GoogleSignIn(serverClientId: webClientId, scopes: ['email']).signIn();
      if (acc == null) return;
      final idt = (await acc.authentication).idToken;
      final r = await http.post(Uri.parse('$base/api/mobile/login'), headers: {'Content-Type': 'application/json'}, body: jsonEncode({'idToken': idt}));
      final j = jsonDecode(r.body);
      if (r.statusCode != 200) throw j['error'] ?? 'server error';
      token = j['token']; user = j['user']; Api.token = token;
      sp.setString('token', token!); sp.setString('user', jsonEncode(user));
      notifyListeners();
      await loadLib();
      if (pending != null) { final p = pending!; pending = null; open(p); }
    } catch (e) { toast('Login failed: $e'); }
  }

  Future<void> logout() async {
    try { await GoogleSignIn().signOut(); } catch (_) {}
    await handler.stop();
    token = null; Api.token = null; sp.remove('token'); queue = []; index = -1; notifyListeners();
  }

  void _lib(dynamic r) {
    List<Track> m(dynamic l) => ((l ?? []) as List).map((e) => Track.fromJson(e)).toList();
    liked = m(r['liked']); recent = m(r['recent']); notifyListeners();
  }
  Future<void> loadLib() async { try { _lib(await Api.get('/api/library')); } catch (_) {} }
  Future<void> toggleLike(Track t) async { try { _lib(await Api.post('/api/library', {'op': 'like', 'track': t.toJson()})); } catch (_) {} }

  Future<void> play(List<Track> l, int i) async { queue = l; index = i; await _load(); }
  void next() { if (queue.isEmpty) return; index = shuffle ? Random().nextInt(queue.length) : (index + 1) % queue.length; _load(); }
  void prev() {
    if (queue.isEmpty) return;
    if (handler.p.position.inSeconds > 3) { handler.p.seek(Duration.zero); return; }
    index = (index - 1 + queue.length) % queue.length; _load();
  }

  Future<void> _load() async {
    final t = cur!, my = ++_tick;
    loading = true; notifyListeners();
    _fetchLyrics(t);
    try {
      String? u = t.audio;
      if (u == null) {
        final r = await Api.get('/api/audio?title=${enc(t.title)}&artist=${enc(t.artist)}');
        u = r['url'] as String?;
      }
      if (my != _tick) return;
      if (u == null) { toast('No audio source available for this song'); loading = false; notifyListeners(); return; }
      handler.mediaItem.add(MediaItem(id: t.id, title: t.title, artist: t.artist, album: t.album, duration: t.duration > 0 ? Duration(milliseconds: t.duration) : null, artUri: t.cover.isEmpty ? null : Uri.tryParse(t.cover)));
      await handler.p.setUrl(u);
      if (my != _tick) return;
      handler.p.play();
      Api.post('/api/library', {'op': 'recent', 'track': t.toJson()}).then(_lib).catchError((_) {});
    } catch (e) { if (my == _tick) toast('Playback failed: $e'); }
    if (my == _tick) { loading = false; notifyListeners(); }
  }

  Future<void> _fetchLyrics(Track t) async {
    lines = []; plain = []; tr = null; lyLoading = true; notifyListeners();
    try {
      final r = await Api.get('/api/lyrics?q=${enc('${t.title} ${t.artist}')}');
      if (cur?.id != t.id) return;
      final re = RegExp(r'^\[(\d+):(\d+\.?\d*)\](.*)');
      lines = ((r['synced'] ?? '') as String).split('\n').map((x) => re.firstMatch(x)).whereType<RegExpMatch>().map((m) => LL(int.parse(m[1]!) * 60 + double.parse(m[2]!), m[3]!.trim())).toList();
      if (lines.isEmpty) plain = ((r['plain'] ?? '') as String).split('\n').map((x) => x.trim()).toList();
    } catch (_) {}
    if (cur?.id == t.id) { lyLoading = false; notifyListeners(); _translate(); }
  }

  Future<void> _translate() async {
    tr = null; notifyListeners();
    final src = lines.isNotEmpty ? lines.map((e) => e.x).toList() : plain;
    if (tl.isEmpty || !src.any((e) => e.isNotEmpty)) return;
    final id = cur?.id;
    try {
      final r = await Api.post('/api/translate', {'to': tl, 'lines': src});
      if (cur?.id != id) return;
      tr = List<String>.from(r['lines'] ?? []); notifyListeners();
    } catch (_) { toast('Could not translate lyrics'); }
  }
  void setLang(String c) { tl = c; sp.setString('tl', c); _translate(); }

  Future<void> shareSong() async {
    final t = cur; if (t == null) return;
    await Share.share('${t.title} - ${t.artist}\n$base/?t=${enc(t.title)}&a=${enc(t.artist)}');
  }
  Future<void> saveLyrics() async {
    final t = cur; if (t == null) return;
    String ts(double s) => '[${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toStringAsFixed(2).padLeft(5, '0')}]';
    final b = StringBuffer('[ti:${t.title}]\n[ar:${t.artist}]\n');
    if (lines.isNotEmpty) {
      for (var k = 0; k < lines.length; k++) {
        b.writeln('${ts(lines[k].t)}${lines[k].x}');
        if (tr != null && k < tr!.length && tr![k].isNotEmpty) b.writeln('${ts(lines[k].t)}${tr![k]}');
      }
    } else if (plain.any((e) => e.isNotEmpty)) {
      for (var k = 0; k < plain.length; k++) { b.writeln(plain[k]); if (tr != null && k < tr!.length && tr![k].isNotEmpty) b.writeln(tr![k]); }
    } else { return toast('No lyrics to save'); }
    final f = File('${(await getTemporaryDirectory()).path}/${'${t.artist} - ${t.title}'.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')}.${lines.isNotEmpty ? 'lrc' : 'txt'}');
    await f.writeAsString(b.toString());
    await Share.shareXFiles([XFile(f.path)]);
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  handler = await AudioService.init(
    builder: () => Handler(),
    config: const AudioServiceConfig(androidNotificationChannelId: 'com.thesync.music.audio', androidNotificationChannelName: 'Playback', androidNotificationOngoing: true),
  );
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});
  @override State<MyApp> createState() => _MyAppState();
}
class _MyAppState extends State<MyApp> {
  @override void initState() { super.initState(); S.init().whenComplete(() { if (!S.ready) { S.ready = true; S.notifyListeners(); } }); }
  @override Widget build(BuildContext c) => MaterialApp(
        title: 'Sync-musiC', debugShowCheckedModeBanner: false, scaffoldMessengerKey: mk,
        theme: ThemeData(brightness: Brightness.dark, useMaterial3: true, scaffoldBackgroundColor: cBg, colorScheme: const ColorScheme.dark(primary: cAc2, secondary: cAc, surface: cPanel)),
        home: ListenableBuilder(listenable: S, builder: (_, __) => !S.ready ? const Scaffold() : S.token == null ? const LoginPage() : const Shell()),
      );
}

Widget pic(String u, {double? size, double r = 8}) {
  final ph = Container(width: size, height: size, color: cCard, child: const Icon(Icons.music_note, color: cMu));
  return ClipRRect(borderRadius: BorderRadius.circular(r), child: u.isEmpty ? ph : Image.network(Api.img(u), width: size, height: size, fit: BoxFit.cover, headers: {'Cookie': Api.cookie}, errorBuilder: (_, __, ___) => ph));
}
const grad = LinearGradient(colors: [cAc, cAc2]);

class LoginPage extends StatelessWidget {
  const LoginPage({super.key});
  @override Widget build(BuildContext c) => Scaffold(
        body: Container(
          decoration: const BoxDecoration(gradient: RadialGradient(center: Alignment(0, -1), radius: 1.2, colors: [Color(0xFF14409F), cBg, Colors.black], stops: [0, .6, 1])),
          child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            ClipRRect(borderRadius: BorderRadius.circular(22), child: Image.asset('assets/logo.png', width: 96, height: 96)),
            const SizedBox(height: 16),
            const Text('Sync-musiC', style: TextStyle(fontSize: 34, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            const Text('Music without ads.', style: TextStyle(color: cMu)),
            const SizedBox(height: 28),
            FilledButton.icon(onPressed: S.login, icon: const Icon(Icons.login), label: const Text('Sign in with Google'), style: FilledButton.styleFrom(backgroundColor: cAc, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 14))),
          ])),
        ),
      );
}

class Shell extends StatefulWidget {
  const Shell({super.key});
  @override State<Shell> createState() => _ShellState();
}
class _ShellState extends State<Shell> {
  int tab = 0;
  @override Widget build(BuildContext c) => ListenableBuilder(
        listenable: S,
        builder: (_, __) => Scaffold(
          body: Container(
            decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF123A9C), Color(0xFF081A52), Color(0xFF03050F)], stops: [0, .35, 1])),
            child: SafeArea(bottom: false, child: IndexedStack(index: tab, children: const [HomeTab(), SearchTab(), LibraryTab()])),
          ),
          bottomNavigationBar: Column(mainAxisSize: MainAxisSize.min, children: [
            const MiniPlayer(),
            NavigationBar(
              backgroundColor: const Color(0xFF03061A), selectedIndex: tab, onDestinationSelected: (i) => setState(() => tab = i),
              destinations: const [
                NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Home'),
                NavigationDestination(icon: Icon(Icons.search), label: 'Search'),
                NavigationDestination(icon: Icon(Icons.library_music_outlined), selectedIcon: Icon(Icons.library_music), label: 'Library'),
              ],
            ),
          ]),
        ),
      );
}

List<Track> tracks(dynamic r) => ((r['results'] ?? []) as List).map((e) => Track.fromJson(e)).toList();

class TrackTile extends StatelessWidget {
  final List<Track> list; final int k;
  const TrackTile(this.list, this.k, {super.key});
  @override Widget build(BuildContext c) {
    final t = list[k], on = S.cur?.id == t.id;
    return ListTile(
      leading: pic(t.cover, size: 48, r: 6),
      title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w600, color: on ? cAc2 : null)),
      subtitle: Text(t.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: cMu)),
      trailing: IconButton(icon: Icon(S.isLiked(t.id) ? Icons.favorite : Icons.favorite_border, color: S.isLiked(t.id) ? cAc2 : cMu), onPressed: () => S.toggleLike(t)),
      onTap: () => S.play(list, k),
    );
  }
}

class HomeTab extends StatefulWidget {
  const HomeTab({super.key});
  @override State<HomeTab> createState() => _HomeTabState();
}
class _HomeTabState extends State<HomeTab> {
  Map<String, List<Track>> shelves = {};
  @override void initState() {
    super.initState();
    for (final q in shelfQ) {
      Api.get('/api/search?type=track&q=${enc(q)}').then((r) { if (mounted) setState(() => shelves[q] = tracks(r)); }).catchError((_) {});
    }
  }
  @override Widget build(BuildContext c) {
    final h = DateTime.now().hour;
    final hi = h < 11 ? 'Good morning' : h < 15 ? 'Good afternoon' : h < 19 ? 'Good evening' : 'Good night';
    return ListView(padding: const EdgeInsets.all(16), children: [
      Row(children: [Expanded(child: Text(hi, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800))), IconButton(icon: const Icon(Icons.logout), onPressed: S.logout)]),
      if (S.recent.isNotEmpty) ...[
        const SizedBox(height: 8),
        Wrap(spacing: 10, runSpacing: 10, children: [
          for (var k = 0; k < min(6, S.recent.length); k++)
            InkWell(onTap: () => S.play(S.recent, k), child: Container(width: (MediaQuery.of(c).size.width - 42) / 2, decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.circular(8)), child: Row(children: [pic(S.recent[k].cover, size: 52, r: 8), const SizedBox(width: 8), Expanded(child: Text(S.recent[k].title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)))]))),
        ]),
      ],
      for (final q in shelfQ)
        if ((shelves[q] ?? []).isNotEmpty) ...[
          Padding(padding: const EdgeInsets.only(top: 22, bottom: 10), child: Text(q, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800))),
          SizedBox(height: 200, child: ListView.separated(scrollDirection: Axis.horizontal, itemCount: min(12, shelves[q]!.length), separatorBuilder: (_, __) => const SizedBox(width: 12), itemBuilder: (_, k) {
            final t = shelves[q]![k];
            return GestureDetector(onTap: () => S.play(shelves[q]!, k), child: SizedBox(width: 140, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [pic(t.cover, size: 140, r: 10), const SizedBox(height: 8), Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)), Text(t.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: cMu, fontSize: 12))])));
          })),
        ],
    ]);
  }
}

class SearchTab extends StatefulWidget {
  const SearchTab({super.key});
  @override State<SearchTab> createState() => _SearchTabState();
}
class _SearchTabState extends State<SearchTab> {
  final ctl = TextEditingController();
  String type = 'track';
  List<Track> res = [];
  bool busy = false;
  Timer? deb;
  void go() {
    deb?.cancel();
    deb = Timer(const Duration(milliseconds: 400), () async {
      if (ctl.text.trim().isEmpty) return setState(() => res = []);
      setState(() => busy = true);
      try { final r = tracks(await Api.get('/api/search?type=$type&q=${enc(ctl.text)}')); if (mounted) setState(() => res = r); } catch (_) {}
      if (mounted) setState(() => busy = false);
    });
  }
  @override Widget build(BuildContext c) => Column(children: [
        Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 4), child: TextField(controller: ctl, onChanged: (_) => go(), decoration: InputDecoration(hintText: 'Search songs, albums, artists', prefixIcon: const Icon(Icons.search), filled: true, fillColor: const Color(0xFF050B26), border: OutlineInputBorder(borderRadius: BorderRadius.circular(30), borderSide: BorderSide.none)))),
        SizedBox(height: 48, child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
          for (final e in const {'track': 'Songs', 'album': 'Albums', 'artist': 'Artists'}.entries)
            Padding(padding: const EdgeInsets.all(4), child: ChoiceChip(label: Text(e.value), selected: type == e.key, onSelected: (_) { type = e.key; res = []; go(); setState(() {}); })),
        ])),
        if (busy) const LinearProgressIndicator(minHeight: 2),
        Expanded(child: ListView.builder(itemCount: res.length, itemBuilder: (_, k) => type == 'track'
            ? TrackTile(res, k)
            : ListTile(leading: pic(res[k].cover, size: 48, r: type == 'artist' ? 24 : 6), title: Text(res[k].title, maxLines: 1, overflow: TextOverflow.ellipsis), subtitle: Text(res[k].artist, style: const TextStyle(color: cMu)), onTap: () { ctl.text = res[k].title; type = 'track'; go(); setState(() {}); }))),
      ]);
}

class LibraryTab extends StatelessWidget {
  const LibraryTab({super.key});
  @override Widget build(BuildContext c) => ListView(padding: const EdgeInsets.all(8), children: [
        const Padding(padding: EdgeInsets.all(12), child: Text('Liked Songs', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800))),
        if (S.liked.isEmpty) const Padding(padding: EdgeInsets.all(12), child: Text('Tap the heart on a song to save it here.', style: TextStyle(color: cMu))),
        for (var k = 0; k < S.liked.length; k++) TrackTile(S.liked, k),
      ]);
}

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});
  @override Widget build(BuildContext c) {
    final t = S.cur;
    if (t == null) return const SizedBox.shrink();
    return InkWell(
      onTap: () => Navigator.push(c, MaterialPageRoute(fullscreenDialog: true, builder: (_) => const NowPlaying())),
      child: Container(color: const Color(0xFF03061A), padding: const EdgeInsets.fromLTRB(12, 8, 4, 8), child: Row(children: [
        pic(t.cover, size: 44, r: 6), const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)), Text(t.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: cMu, fontSize: 12))])),
        PlayBtn(size: 30),
      ])),
    );
  }
}

class PlayBtn extends StatelessWidget {
  final double size;
  const PlayBtn({super.key, this.size = 36});
  @override Widget build(BuildContext c) => StreamBuilder<bool>(
        stream: handler.p.playingStream, initialData: false,
        builder: (_, s) => S.loading
            ? SizedBox(width: size + 16, height: size + 16, child: Padding(padding: const EdgeInsets.all(12), child: const CircularProgressIndicator(strokeWidth: 3)))
            : IconButton(iconSize: size, icon: Icon(s.data == true ? Icons.pause : Icons.play_arrow), onPressed: () => s.data == true ? handler.pause() : handler.play()),
      );
}

String fmt(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

class NowPlaying extends StatefulWidget {
  const NowPlaying({super.key});
  @override State<NowPlaying> createState() => _NowPlayingState();
}
class _NowPlayingState extends State<NowPlaying> {
  bool ly = false;
  void langSheet() => showModalBottomSheet(context: context, backgroundColor: cPanel, builder: (_) => ListView(children: [
        const Padding(padding: EdgeInsets.all(16), child: Text('Translate lyrics', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
        for (final e in langs.entries) ListTile(title: Text(e.value), trailing: S.tl == e.key ? const Icon(Icons.check, color: cAc2) : null, onTap: () { S.setLang(e.key); Navigator.pop(context); }),
      ]));
  @override Widget build(BuildContext c) => ListenableBuilder(listenable: S, builder: (_, __) {
        final t = S.cur;
        if (t == null) return const Scaffold();
        return Scaffold(
          body: Container(
            decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF0F3AA8), Color(0xFF050C2E), Colors.black], stops: [0, .55, 1])),
            child: SafeArea(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: Column(children: [
              Row(children: [
                IconButton(icon: const Icon(Icons.keyboard_arrow_down, size: 32), onPressed: () => Navigator.pop(c)),
                Expanded(child: Column(children: [Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800)), Text(t.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: cMu, fontSize: 13))])),
                IconButton(icon: Icon(Icons.lyrics_outlined, color: ly ? cAc2 : null), onPressed: () => setState(() => ly = !ly)),
              ]),
              Expanded(child: ly ? const LyricsView() : Center(child: AspectRatio(aspectRatio: 1, child: pic(t.cover, r: 16)))),
              const SizedBox(height: 8),
              Row(children: [
                if (ly) ActionChip(avatar: const Icon(Icons.translate, size: 18), label: Text(S.tl.isEmpty ? 'OFF' : S.tl.split('-')[0].toUpperCase()), onPressed: langSheet),
                const Spacer(),
                IconButton(icon: Icon(S.isLiked(t.id) ? Icons.favorite : Icons.favorite_border, color: S.isLiked(t.id) ? cAc2 : null), onPressed: () => S.toggleLike(t)),
                IconButton(icon: const Icon(Icons.download_outlined), tooltip: 'Save lyrics', onPressed: S.saveLyrics),
                IconButton(icon: const Icon(Icons.share_outlined), onPressed: S.shareSong),
              ]),
              StreamBuilder<Duration>(stream: handler.p.positionStream, builder: (_, s) {
                final pos = s.data ?? Duration.zero, tot = handler.p.duration ?? Duration(milliseconds: t.duration);
                final mx = max(tot.inMilliseconds, 1).toDouble();
                return Column(children: [
                  Slider(value: min(pos.inMilliseconds.toDouble(), mx), max: mx, onChanged: (v) => handler.p.seek(Duration(milliseconds: v.toInt()))),
                  Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(fmt(pos), style: const TextStyle(color: cMu, fontSize: 12)), Text(fmt(tot), style: const TextStyle(color: cMu, fontSize: 12))])),
                ]);
              }),
              Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                IconButton(icon: Icon(Icons.shuffle, color: S.shuffle ? cAc2 : cMu), onPressed: () { S.shuffle = !S.shuffle; S.notifyListeners(); }),
                IconButton(iconSize: 36, icon: const Icon(Icons.skip_previous), onPressed: S.prev),
                Container(decoration: const BoxDecoration(shape: BoxShape.circle, gradient: grad), child: const PlayBtn(size: 40)),
                IconButton(iconSize: 36, icon: const Icon(Icons.skip_next), onPressed: S.next),
                IconButton(icon: Icon(Icons.repeat, color: S.repeat ? cAc2 : cMu), onPressed: () { S.repeat = !S.repeat; S.notifyListeners(); }),
              ]),
              const SizedBox(height: 12),
            ]))),
          ),
        );
      });
}

class LyricsView extends StatefulWidget {
  const LyricsView({super.key});
  @override State<LyricsView> createState() => _LyricsViewState();
}
class _LyricsViewState extends State<LyricsView> {
  List<GlobalKey> keys = [];
  int last = -1;
  @override Widget build(BuildContext c) {
    if (S.lyLoading) return const Center(child: CircularProgressIndicator());
    final syn = S.lines.isNotEmpty;
    final src = syn ? S.lines.map((e) => e.x).toList() : S.plain;
    if (!src.any((e) => e.isNotEmpty)) return const Center(child: Text('Lyrics not found.', style: TextStyle(color: cMu)));
    if (keys.length != src.length) keys = List.generate(src.length, (_) => GlobalKey());
    return StreamBuilder<Duration>(stream: handler.p.positionStream, builder: (_, s) {
      final pos = (s.data ?? Duration.zero).inMilliseconds / 1000;
      final act = syn ? S.lines.lastIndexWhere((l) => l.t <= pos) : -1;
      if (act != last && act >= 0) {
        last = act;
        WidgetsBinding.instance.addPostFrameCallback((_) { final x = keys[act].currentContext; if (x != null) Scrollable.ensureVisible(x, alignment: .35, duration: const Duration(milliseconds: 350), curve: Curves.easeOut); });
      }
      return SingleChildScrollView(padding: const EdgeInsets.symmetric(vertical: 24), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (var k = 0; k < src.length; k++)
          src[k].isEmpty ? const SizedBox(height: 14) : GestureDetector(
            key: keys[k], behavior: HitTestBehavior.opaque,
            onTap: syn ? () => handler.p.seek(Duration(milliseconds: (S.lines[k].t * 1000).toInt())) : null,
            child: Padding(padding: const EdgeInsets.only(bottom: 22), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(src[k], style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, height: 1.25, color: !syn || k == act ? Colors.white : Colors.white38)),
              if (S.tr != null && k < S.tr!.length && S.tr![k].isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text(S.tr![k], style: TextStyle(fontSize: 17, color: !syn || k == act ? Colors.white : Colors.white30))),
            ])),
          ),
      ]));
    });
  }
}

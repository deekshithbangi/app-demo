// WhatsApp Image Gallery - Single File Implementation
//
// Notes:
// - This file contains all logic, UI, state management (Provider), and Hive persistence.
// - On Android: Scans the WhatsApp Images directory at:
//     /storage/emulated/0/WhatsApp/Media/WhatsApp Images/
// - On Non-Android platforms (including Web / Codespaces) it loads mock data so you can
//   still see the UI and interact with search / timeline logic.
// - Dark mode follows the system (ThemeMode.system).
// - Smooth UI touches: Hero animations, implicit animations, fade-in images,
//   pull-to-refresh, shimmer-like placeholders with AnimatedSwitcher, and efficient
//   lazy grids.
//
// Permissions (Android):
// - Pre Android 13: READ/WRITE_EXTERNAL_STORAGE (permission_handler: Permission.storage).
// - Android 13+: Use READ_MEDIA_IMAGES (permission_handler maps via Permission.photos
//   (or still storage depending on version); here we request both defensively).
//
// Deletion:
// - Deletes the actual file (Android only) and removes from Hive.
// - On non-Android demo mode, deletion is simulated (removes from Hive only).
//
// Hive Structure:
// - Box "imagesBox": List of image entry maps
//     {
//       'path': String,
//       'date': String (ISO8601),
//       'contactId': String
//     }
// - We derive albums on the fly. We also store a lightweight "cache" in memory via Provider.
//
// Contact naming heuristic:
// - WhatsApp typical pattern: IMG-YYYYMMDD-WA####.jpg
// - We parse WA + digits as a contact identifier (WA0001 -> "WA0001").
// - Unknown patterns fall into "Unknown".
//
// Extensibility Suggestions (Not implemented here to keep single-file constraint):
// - Add a ContactAdapter with Hive TypeAdapters
// - Add actual contact name resolution using contacts_service plugin
// - Pagination & background isolates for scanning large directories
//
// DISCLAIMER: Accessing /storage/emulated/0/... requires real device/emulator; this path
// changed for scoped storage on Android 11+. Real production app should use MediaStore
// queries instead of raw file path scanning for robustness.
//
// ---------------------------------------------------------------------------

import 'dart:async';
import 'dart:io' show Directory, File, Platform;
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:transparent_image/transparent_image.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  await Hive.openBox('imagesBox');
  runApp(const WhatsAppGalleryApp());
}

class WhatsAppGalleryApp extends StatelessWidget {
  const WhatsAppGalleryApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<ImageRepository>(
          create: (_) => ImageRepository()..init(),
        ),
        ChangeNotifierProxyProvider<ImageRepository, TimelineFilterProvider>(
          create: (_) => TimelineFilterProvider(),
          update: (_, repo, timeline) => timeline!..bind(repo),
        ),
        ChangeNotifierProvider<AlbumSearchProvider>(
          create: (_) => AlbumSearchProvider(),
        ),
      ],
      child: Consumer<ImageRepository>(
        builder: (context, repo, _) {
          return MaterialApp(
            title: 'WhatsApp Image Gallery',
            debugShowCheckedModeBanner: false,
            themeMode: ThemeMode.system,
            theme: ThemeData(
              useMaterial3: true,
              colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
              brightness: Brightness.light,
            ),
            darkTheme: ThemeData(
              useMaterial3: true,
              colorScheme: ColorScheme.fromSeed(
                seedColor: Colors.green,
                brightness: Brightness.dark,
              ),
              brightness: Brightness.dark,
            ),
            home: const RootScaffold(),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// MODELS
// ---------------------------------------------------------------------------

class ImageEntry {
  final String path;
  final DateTime date;
  final String contactId;

  ImageEntry({
    required this.path,
    required this.date,
    required this.contactId,
  });

  Map<String, dynamic> toMap() => {
        'path': path,
        'date': date.toIso8601String(),
        'contactId': contactId,
      };

  static ImageEntry fromMap(Map map) => ImageEntry(
        path: map['path'] as String,
        date: DateTime.tryParse(map['date'] as String? ?? '') ?? DateTime.now(),
        contactId: map['contactId'] as String? ?? 'Unknown',
      );
}

// ---------------------------------------------------------------------------
// PROVIDERS
// ---------------------------------------------------------------------------

class ImageRepository extends ChangeNotifier {
  static const String imagesBoxName = 'imagesBox';
  static const String whatsAppDirPath =
      '/storage/emulated/0/WhatsApp/Media/WhatsApp Images';

  final List<ImageEntry> _images = [];
  bool _loading = false;
  bool _permissionDenied = false;
  bool _initialized = false;
  bool _usingMock = false;
  DateTime? _lastScan;

  bool get isLoading => _loading;
  bool get permissionDenied => _permissionDenied;
  bool get initialized => _initialized;
  bool get usingMock => _usingMock;
  DateTime? get lastScan => _lastScan;

  List<ImageEntry> get images => List.unmodifiable(_images);

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    await _loadFromHive();
    // Attempt scan if on Android; else load mock
    if (Platform.isAndroid) {
      await requestPermissions();
      if (!_permissionDenied) {
        unawaited(scanAndSync(rescan: false));
      }
    } else {
      // Mock data for non-Android (e.g., Codespaces / Web / Desktop)
      _usingMock = true;
      if (_images.isEmpty) {
        _populateMockData();
        await _persist();
      }
      notifyListeners();
    }
  }

  Future<void> requestPermissions() async {
    if (!Platform.isAndroid) return;
    // Try multiple relevant permissions (some may be auto-granted)
    final statuses = await [
      Permission.storage,
      Permission.photos,
    ].request();

    if (statuses.values.any((s) => s.isGranted)) {
      _permissionDenied = false;
    } else {
      _permissionDenied = true;
    }
    notifyListeners();
  }

  Future<void> scanAndSync({bool rescan = true}) async {
    if (!Platform.isAndroid || _permissionDenied) return;
    if (_loading) return;
    _loading = true;
    notifyListeners();

    try {
      final dir = Directory(whatsAppDirPath);
      if (!dir.existsSync()) {
        // Directory not found; keep existing images
        _loading = false;
        notifyListeners();
        return;
      }

      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => _isSupportedImage(f.path))
          .toList();

      final parsed = <ImageEntry>[];
      for (final file in files) {
        final stat = await file.stat();
        final contactId = _extractContactId(file.path);
        parsed.add(ImageEntry(
          path: file.path,
            // Use file modified time for chronological grouping
          date: stat.modified,
          contactId: contactId,
        ));
      }

      _images
        ..clear()
        ..addAll(parsed);
      _lastScan = DateTime.now();
      await _persist();
    } catch (e) {
      debugPrint('Scan error: $e');
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> deleteImage(ImageEntry entry) async {
    // Remove from disk only on Android non-mock
    if (Platform.isAndroid && !_usingMock) {
      final file = File(entry.path);
      if (await file.exists()) {
        try {
          await file.delete();
        } catch (e) {
          debugPrint('Delete file error: $e');
        }
      }
    }
    _images.removeWhere((img) => img.path == entry.path);
    await _persist();
    notifyListeners();
  }

  Map<String, List<ImageEntry>> get albums {
    final map = <String, List<ImageEntry>>{};
    for (final img in _images) {
      map.putIfAbsent(img.contactId, () => []).add(img);
    }
    // Sort each album by newest first
    for (final list in map.values) {
      list.sort((a, b) => b.date.compareTo(a.date));
    }
    return map;
  }

  List<ImageEntry> imagesInLast(Duration d) {
    final cutoff = DateTime.now().subtract(d);
    return _images.where((img) => img.date.isAfter(cutoff)).toList()
      ..sort((a, b) => b.date.compareTo(a.date));
  }

  Future<void> _loadFromHive() async {
    final box = Hive.box(imagesBoxName);
    final raw = (box.get('images') as List?)?.cast<Map>() ?? [];
    _images
      ..clear()
      ..addAll(raw.map(ImageEntry.fromMap));
    notifyListeners();
  }

  Future<void> _persist() async {
    final box = Hive.box(imagesBoxName);
    await box.put('images', _images.map((e) => e.toMap()).toList());
  }

  bool _isSupportedImage(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.webp');
  }

  String _extractContactId(String path) {
    // Typical name: .../IMG-20230510-WA0001.jpg
    final fileName = path.split('/').last;
    final regex = RegExp(r'WA\d+');
    final match = regex.firstMatch(fileName);
    if (match != null) {
      return match.group(0)!; // e.g., WA0001
    }
    return 'Unknown';
  }

  void _populateMockData() {
    final now = DateTime.now();
    for (int i = 0; i < 30; i++) {
      final dayOffset = i % 10;
      final contact = 'WA${(i % 5 + 1).toString().padLeft(4, '0')}';
      _images.add(ImageEntry(
        path: 'mock/path/IMG-${now.subtract(Duration(days: dayOffset)).millisecondsSinceEpoch}-$contact-$i.jpg',
        date: now.subtract(Duration(
            days: dayOffset,
            hours: i,
            minutes: (i * 7) % 60,
            seconds: (i * 13) % 60)),
        contactId: contact,
      ));
    }
  }
}

class TimelineFilterProvider extends ChangeNotifier {
  ImageRepository? _repo;
  TimelineRange _range = TimelineRange.today;

  void bind(ImageRepository repo) {
    if (_repo != repo) {
      _repo = repo;
      notifyListeners();
    }
  }

  TimelineRange get range => _range;

  void setRange(TimelineRange r) {
    if (_range != r) {
      _range = r;
      notifyListeners();
    }
  }

  List<ImageEntry> get filtered {
    if (_repo == null) return [];
    switch (_range) {
      case TimelineRange.today:
        return _repo!.imagesInLast(const Duration(hours: 24));
      case TimelineRange.week:
        return _repo!.imagesInLast(const Duration(days: 7));
      case TimelineRange.month:
        return _repo!.imagesInLast(const Duration(days: 30));
    }
  }
}

enum TimelineRange { today, week, month }

class AlbumSearchProvider extends ChangeNotifier {
  String _query = '';

  String get query => _query;

  void setQuery(String v) {
    if (_query != v) {
      _query = v;
      notifyListeners();
    }
  }
}

// ---------------------------------------------------------------------------
// ROOT SCAFFOLD WITH BOTTOM NAV
// ---------------------------------------------------------------------------

class RootScaffold extends StatefulWidget {
  const RootScaffold({super.key});

  @override
  State<RootScaffold> createState() => _RootScaffoldState();
}

class _RootScaffoldState extends State<RootScaffold> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<ImageRepository>();
    final pages = [
      const AlbumsTab(),
      const TimelineTab(),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('WhatsApp Image Gallery'),
        actions: [
          if (_index == 0) const _AlbumsSearchField(),
          IconButton(
            tooltip: 'Rescan',
            icon: repo.isLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            onPressed: repo.isLoading
                ? null
                : () async {
                    if (!repo.initialized) return;
                    if (repo.permissionDenied && Platform.isAndroid) {
                      await repo.requestPermissions();
                      if (!repo.permissionDenied) {
                        await repo.scanAndSync(rescan: true);
                      }
                    } else {
                      await repo.scanAndSync(rescan: true);
                    }
                  },
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        child: pages[_index],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
            NavigationDestination(
              icon: Icon(Icons.photo_album_outlined),
              selectedIcon: Icon(Icons.photo_album),
              label: 'Albums',
            ),
            NavigationDestination(
              icon: Icon(Icons.timeline_outlined),
              selectedIcon: Icon(Icons.timeline),
              label: 'Timeline',
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// ALBUMS TAB
// ---------------------------------------------------------------------------

class AlbumsTab extends StatelessWidget {
  const AlbumsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<ImageRepository>();
    final search = context.watch<AlbumSearchProvider>().query.trim().toLowerCase();

    Widget body;
    if (repo.permissionDenied && Platform.isAndroid) {
      body = _PermissionDeniedMessage(onRetry: () => repo.requestPermissions());
    } else if (repo.isLoading && repo.images.isEmpty) {
      body = const _CenteredLoading(message: 'Scanning WhatsApp Images...');
    } else if (repo.images.isEmpty) {
      body = const _EmptyState(message: 'No images found.');
    } else {
      final albums = repo.albums.entries.toList()
        ..sort(
          (a, b) => b.value.first.date.compareTo(a.value.first.date),
        );

      final filtered = albums.where((entry) {
        if (search.isEmpty) return true;
        final name = _contactDisplayName(entry.key).toLowerCase();
        return name.contains(search);
      }).toList();

      body = RefreshIndicator(
        onRefresh: () => repo.scanAndSync(rescan: true),
        child: GridView.builder(
          padding: const EdgeInsets.all(12),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisExtent: 140,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
          ),
          itemCount: filtered.length,
          itemBuilder: (context, i) {
            final entry = filtered[i];
            final albumId = entry.key;
            final images = entry.value;
            final cover = images.firstOrNull;
            return _AlbumCard(
              albumId: albumId,
              cover: cover,
              count: images.length,
              onTap: () {
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => AlbumDetailPage(
                    albumId: albumId,
                    images: images,
                  ),
                ));
              },
            );
          },
        ),
      );
    }

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 350),
      child: body,
    );
  }
}

class _AlbumsSearchField extends StatelessWidget {
  const _AlbumsSearchField();

  @override
  Widget build(BuildContext context) {
    final searchProvider = context.read<AlbumSearchProvider>();
    return SizedBox(
      width: 170,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: TextField(
          onChanged: searchProvider.setQuery,
          decoration: InputDecoration(
            hintText: 'Search',
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            filled: true,
            fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(24),
              borderSide: BorderSide.none,
            ),
            prefixIcon: const Icon(Icons.search, size: 18),
          ),
        ),
      ),
    );
  }
}

class _AlbumCard extends StatelessWidget {
  final String albumId;
  final ImageEntry? cover;
  final int count;
  final VoidCallback onTap;

  const _AlbumCard({
    required this.albumId,
    required this.cover,
    required this.count,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final displayName = _contactDisplayName(albumId);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Ink(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            children: [
              Hero(
                tag: 'album-$albumId',
                child: ClipOval(
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: cover == null
                        ? Container(
                            color: Theme.of(context)
                                .colorScheme
                                .surfaceContainerHigh,
                            child: const Icon(Icons.person, size: 40),
                          )
                        : _FadeInThumbnail(path: cover!.path),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              Text(
                '$count',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// TIMELINE TAB
// ---------------------------------------------------------------------------

class TimelineTab extends StatelessWidget {
  const TimelineTab({super.key});

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<ImageRepository>();
    final timeline = context.watch<TimelineFilterProvider>();

    if (repo.permissionDenied && Platform.isAndroid) {
      return _PermissionDeniedMessage(onRetry: () => repo.requestPermissions());
    }

    final images = timeline.filtered;
    Widget body;
    if (repo.isLoading && images.isEmpty) {
      body = const _CenteredLoading(message: 'Loading timeline...');
    } else if (images.isEmpty) {
      body = const _EmptyState(message: 'No images for selected range.');
    } else {
      body = GridView.builder(
        padding: const EdgeInsets.all(8),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: 4,
          crossAxisSpacing: 4,
        ),
        itemCount: images.length,
        itemBuilder: (context, index) {
          final img = images[index];
          return GestureDetector(
            onTap: () => _openFullScreen(context, img),
            child: Hero(
              tag: img.path,
              child: _FadeInThumbnail(path: img.path),
            ),
          );
        },
      );
    }

    return Column(
      children: [
        _TimelineRangeSelector(
          selected: timeline.range,
          onChanged: timeline.setRange,
        ),
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: body,
          ),
        ),
      ],
    );
  }
}

class _TimelineRangeSelector extends StatelessWidget {
  final TimelineRange selected;
  final ValueChanged<TimelineRange> onChanged;

  const _TimelineRangeSelector({
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final items = [
      (TimelineRange.today, 'Today'),
      (TimelineRange.week, 'This Week'),
      (TimelineRange.month, 'This Month'),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: SegmentedButton<TimelineRange>(
        segments: items
            .map(
              (e) => ButtonSegment<TimelineRange>(
                value: e.$1,
                label: Text(e.$2),
              ),
            )
            .toList(),
        selected: {selected},
        onSelectionChanged: (set) {
          if (set.isNotEmpty) onChanged(set.first);
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// ALBUM DETAIL PAGE
// ---------------------------------------------------------------------------

class AlbumDetailPage extends StatelessWidget {
  final String albumId;
  final List<ImageEntry> images;

  const AlbumDetailPage({
    super.key,
    required this.albumId,
    required this.images,
  });

  @override
  Widget build(BuildContext context) {
    final displayName = _contactDisplayName(albumId);
    return Scaffold(
      appBar: AppBar(
        title: Text(displayName),
      ),
      body: images.isEmpty
          ? const _EmptyState(message: 'No images in this album.')
          : GridView.builder(
              padding: const EdgeInsets.all(6),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3, mainAxisSpacing: 4, crossAxisSpacing: 4),
              itemCount: images.length,
              itemBuilder: (context, index) {
                final img = images[index];
                return _AlbumImageTile(entry: img);
              },
            ),
    );
  }
}

class _AlbumImageTile extends StatelessWidget {
  final ImageEntry entry;
  const _AlbumImageTile({required this.entry});

  @override
  Widget build(BuildContext context) {
    final repo = context.read<ImageRepository>();
    return GestureDetector(
      onTap: () => _openFullScreen(context, entry),
      onLongPress: () async {
        final confirm = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Delete Image'),
            content: const Text(
                'This will delete the file (if on Android) and remove it from the gallery. Continue?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        );
        if (confirm == true) {
          await repo.deleteImage(entry);
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Image deleted')),
            );
          }
        }
      },
      child: Hero(
        tag: entry.path,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _FadeInThumbnail(path: entry.path),
            Positioned(
              bottom: 2,
              right: 2,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  _shortDate(entry.date),
                  style: const TextStyle(fontSize: 10, color: Colors.white),
                ),
              ),
            )
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// IMAGE VIEWER
// ---------------------------------------------------------------------------

void _openFullScreen(BuildContext context, ImageEntry entry) {
  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => _FullScreenImage(entry: entry),
  ));
}

class _FullScreenImage extends StatelessWidget {
  final ImageEntry entry;
  const _FullScreenImage({required this.entry});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black54,
        title: Text(_shortDateTime(entry.date)),
      ),
      body: Center(
        child: Hero(
          tag: entry.path,
          child: InteractiveViewer(
            panEnabled: true,
            minScale: 0.5,
            maxScale: 4,
            child: _DisplayImage(path: entry.path),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// IMAGE DISPLAY WIDGETS
// ---------------------------------------------------------------------------

class _FadeInThumbnail extends StatelessWidget {
  final String path;
  const _FadeInThumbnail({required this.path});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: _DisplayImage(path: path),
    );
  }
}

class _DisplayImage extends StatelessWidget {
  final String path;
  const _DisplayImage({required this.path});

  @override
  Widget build(BuildContext context) {
    if (!Platform.isAndroid) {
      // Mock / fallback: colored container with initials
      final baseColor = Theme.of(context).colorScheme.primaryContainer;
      final hash = path.hashCode;
      final modColor = HSLColor.fromColor(baseColor)
          .withHue((hash % 360).toDouble())
          .toColor();
      return Container(
        color: modColor,
        alignment: Alignment.center,
        child: Text(
          'IMG',
          style: Theme.of(context)
              .textTheme
              .titleLarge
              ?.copyWith(color: Colors.white70, fontWeight: FontWeight.bold),
        ),
      );
    }

    final file = File(path);
    if (!file.existsSync()) {
      return Container(
        color: Colors.grey.shade800,
        alignment: Alignment.center,
        child: const Icon(Icons.broken_image, color: Colors.white54),
      );
    }

    return Image.file(
      file,
      fit: BoxFit.cover,
      frameBuilder: (context, child, frame, wasSync) {
        if (frame == null) {
          return AnimatedOpacity(
            opacity: 0.2,
            duration: const Duration(milliseconds: 300),
            child: Container(
              color: Colors.grey.shade700,
            ),
          );
        }
        return AnimatedOpacity(
          opacity: 1,
          duration: const Duration(milliseconds: 300),
          child: child,
        );
      },
      errorBuilder: (_, __, ___) => Container(
        color: Colors.grey.shade900,
        child: const Icon(Icons.error, color: Colors.redAccent),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// GENERIC UI HELPERS
// ---------------------------------------------------------------------------

class _CenteredLoading extends StatelessWidget {
  final String message;
  const _CenteredLoading({required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 16),
        Text(message),
      ]),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final String message;
  const _EmptyState({required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        message,
        style:
            Theme.of(context).textTheme.titleMedium?.copyWith(color: Colors.grey),
      ),
    );
  }
}

class _PermissionDeniedMessage extends StatelessWidget {
  final VoidCallback onRetry;
  const _PermissionDeniedMessage({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock, size: 64),
            const SizedBox(height: 16),
            Text(
              'Storage Permission Required',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            const Text(
              'Grant storage / media permissions to scan WhatsApp images.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: onRetry,
              child: const Text('Grant Permission'),
            )
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// HELPERS
// ---------------------------------------------------------------------------

String _contactDisplayName(String contactId) {
  if (contactId == 'Unknown') return 'Unknown';
  return contactId; // Could map to actual name if available
}

String _shortDate(DateTime dt) {
  final now = DateTime.now();
  if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
  return '${dt.month}/${dt.day}';
}

String _shortDateTime(DateTime dt) {
  return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
}
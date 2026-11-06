import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mangayomi/eval/dart/service.dart';
import 'package:mangayomi/eval/model/filter.dart';
import 'package:mangayomi/main.dart' as app;
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/source.dart';
import 'package:mangayomi/providers/storage_provider.dart';
import 'package:mangayomi/repositories/source_preference_repository.dart';
import 'package:mangayomi/repositories/source_repository.dart';
import 'package:mangayomi/services/extension_preferences_service.dart';
import 'package:mangayomi/services/http/m_client.dart';

/// Runs a real local extension source through the app's D4rt extension
/// runtime on a device. The source is supplied at build time:
///
///   flutter test integration_test/extension_runtime_test.dart \
///     -d emulator-5554 \
///     --dart-define=EXT_SOURCE_B64="$(base64 -w0 <source.dart>)"
///
/// Optionally pass `--dart-define=EPISODE_URL=https://...` to skip discovery.
/// Optionally pass `--dart-define=MIRROR=gofile|pixeldrain` to test a download
/// mirror instead of the default stream mode.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('extension runtime resolves stream and download mirrors', (tester) async {
    const encoded = String.fromEnvironment('EXT_SOURCE_B64');
    const directEpisode = String.fromEnvironment('EPISODE_URL');
    const mirrorChoice = String.fromEnvironment('MIRROR');
    const downloadQuality = String.fromEnvironment('DOWNLOAD_QUALITY');
    const popularOnly = String.fromEnvironment('POPULAR_ONLY') == '1';
    const searchQuery = String.fromEnvironment('SEARCH_QUERY');
    const searchFilters = String.fromEnvironment('SEARCH_FILTERS') == '1';
    expect(
      encoded,
      isNotEmpty,
      reason: 'pass --dart-define=EXT_SOURCE_B64 from a local source.dart',
    );

    final sourceCode = utf8.decode(base64Decode(encoded));
    final report = await tester.runAsync(() async {
      final db = await StorageProvider().initDB(null);
      app.isar = db;
      await webviewServer();

      final sourceRepository = SourceRepository();
      final testName = [
        'Local Extension',
        if (mirrorChoice.isNotEmpty) mirrorChoice,
        if (downloadQuality.isNotEmpty) 'dl$downloadQuality',
      ].join('-');
      final source = Source(
        id: 'mangayomi-id.$testName'.hashCode,
        name: testName,
        lang: 'id',
        baseUrl: 'https://v2.samehadaku.how',
        isActive: true,
        isAdded: true,
        isLocal: true,
        itemType: ItemType.anime,
        typeSource: 'single',
        version: '0.0.1',
        sourceCode: sourceCode,
      )..sourceCodeLanguage = SourceCodeLanguage.dart;
      await sourceRepository.save(source);
      final installed = sourceRepository.getById(source.id!);
      expect(installed, isNotNull, reason: 'source must be saved in Isar');
      final installedSource = installed!;
      expect(installedSource.sourceCode, isNotEmpty);
      expect(
        sourceRepository
            .getAllOrInstalled(installedOnly: true)
            .any((item) => item.id == installedSource.id),
        isTrue,
        reason: 'installed extension list must expose the local extension',
      );

      if (mirrorChoice.isNotEmpty) {
        final prefRepo = SourcePreferenceRepository();
        getPreferenceValue(installedSource.id!, "mirror_v2");
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final pref = prefRepo.findByKey(installedSource.id, "mirror_v2");
        expect(pref, isNotNull, reason: 'mirror preference must be created');
        final index = pref!.listPreference!.entryValues!.indexOf(mirrorChoice);
        expect(index, greaterThanOrEqualTo(0));
        pref.listPreference!.valueIndex = index;
        await prefRepo.save(pref, installedSource, pref);
      }

      if (downloadQuality.isNotEmpty) {
        final prefRepo = SourcePreferenceRepository();
        getPreferenceValue(installedSource.id!, "download_quality");
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final pref = prefRepo.findByKey(installedSource.id, "download_quality");
        expect(
          pref,
          isNotNull,
          reason: 'download quality preference must be created',
        );
        final index = pref!.listPreference!.entryValues!.indexOf(
          downloadQuality,
        );
        expect(index, greaterThanOrEqualTo(0));
        pref.listPreference!.valueIndex = index;
        await prefRepo.save(pref, installedSource, pref);
      }

      final service = DartExtensionService(installedSource);
      final out = <String, dynamic>{};
      try {
        if (directEpisode.isNotEmpty) {
          out['episode'] = directEpisode;
          out['videos'] = _describe(await service.getVideoList(directEpisode));
          return out;
        }

        if (searchQuery.isNotEmpty) {
          List<dynamic> filters = [];
          if (searchFilters) {
            final filterList = service.getFilterList();
            for (final filter in filterList.filters) {
              if (filter is SelectFilter) {
                if (filter.type == 'status') filter.state = 2;
                if (filter.type == 'order') filter.state = 4;
              } else if (filter is GroupFilter) {
                for (final item in filter.state) {
                  if (item is CheckBoxFilter && item.value == 'action') {
                    item.state = true;
                  }
                }
              }
            }
            filters = filterList.filters;
          }
          final result = await service.search(searchQuery, 1, filters);
          out['search'] = result.list
              .take(10)
              .map((manga) => manga.name)
              .toList();
          out['searchCount'] = result.list.length;
          out['searchHasNext'] = result.hasNextPage;
          out['videos'] = <String>[];
          return out;
        }

        final popular = await service.getPopular(1);
        out['popular'] = popular.list
            .take(5)
            .map((manga) => manga.name)
            .toList();
        out['popularCount'] = popular.list.length;
        if (popularOnly) {
          out['videos'] = <String>[];
          return out;
        }

        final latest = await service.getLatestUpdates(1);
        out['latest'] = latest.list.length;
        for (final manga in latest.list.take(5)) {
          final detail = await service.getDetail(manga.link!);
          final chapters = detail.chapters ?? [];
          out['series'] = manga.name;
          out['seriesLink'] = manga.link;
          for (final chapter in chapters.take(2)) {
            final videos = await service.getVideoList(chapter.url!);
            final vip = videos.where((v) => v.quality == 'VIP STREAMING');
            if (vip.isNotEmpty) {
              out['episode'] = chapter.name;
              out['chapterUrl'] = chapter.url;
              out['videos'] = _describe(vip.toList());
              return out;
            }
          }
        }
        out['videos'] = <String>[];
        out['note'] = 'no VIP video in the first 5 series';
        return out;
      } finally {
        service.dispose();
        await stopwebviewServer();
        await db.close();
      }
    });

    // ignore: avoid_print
    print('EXT RESULT: $report');
    expect(report, isNotNull);
    final data = report!;
    final searchNames = (data['search'] as List?) ?? <dynamic>[];
    if (searchQuery.isNotEmpty) {
      expect(searchNames.length, greaterThanOrEqualTo(1));
      expect(
        searchNames.every((name) => name.toString().trim().isNotEmpty),
        isTrue,
        reason: 'search results must have titles',
      );
      return;
    }
    if (directEpisode.isEmpty) {
      final popularNames = (data['popular'] as List?) ?? <dynamic>[];
      expect(popularNames.length, greaterThanOrEqualTo(1));
      expect(
        popularNames.every((name) => name.toString().trim().isNotEmpty),
        isTrue,
        reason: 'popular entries must have titles',
      );
    }
    if (popularOnly) return;
    final videos = (data['videos'] as List?) ?? <dynamic>[];
    final qualities = videos.map((video) => (video as Map)['quality']).toSet();
    if (mirrorChoice == 'pixeldrain') {
      expect(
        qualities.every((q) => q.toString().startsWith('Pixeldrain')),
        isTrue,
      );
      expect(qualities.length, greaterThanOrEqualTo(1));
      if (downloadQuality.isNotEmpty) {
        expect(qualities, contains('Pixeldrain $downloadQuality'));
      }
    } else if (mirrorChoice == 'gofile') {
      final expected = downloadQuality.isEmpty
          ? 'Gofile 1080p'
          : 'Gofile $downloadQuality';
      expect(qualities, contains(expected));
      expect(
        videos.any(
          (video) =>
              (video as Map)['quality'] == expected &&
              (video['url'] as String).contains('.mkv'),
        ),
        isTrue,
      );
    } else if (directEpisode.isNotEmpty) {
      if (downloadQuality.isNotEmpty) {
        expect(qualities, contains('Download $downloadQuality'));
        final firstMedia = videos.firstWhere(
          (video) =>
              ((video as Map)['originalUrl'] as String).contains('.mkv') ||
              (video['url'] as String).contains('.mkv') ||
              (video['url'] as String).contains('.mp4'),
        );
        expect(
          (firstMedia as Map)['quality'],
          'Download $downloadQuality',
          reason: 'download must pick the selected quality first',
        );
      } else {
        expect(qualities, containsAll(['Blogspot', 'VIP STREAMING']));
      }
      final blogspot = videos.firstWhere(
        (video) => (video as Map)['quality'] == 'Blogspot',
      );
      expect(
        (blogspot as Map)['url'],
        contains('googlevideo.com/videoplayback'),
      );
    } else {
      expect(
        videos.any(
          (video) =>
              video is Map &&
              video['quality'] == 'VIP STREAMING' &&
              (video['url'] as String).contains('.mkv'),
        ),
        isTrue,
        reason: 'VIP STREAMING must resolve to a direct .mkv URL',
      );
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}

List<Map<String, String>> _describe(List<dynamic> videos) => videos
    .map(
      (dynamic video) => {
        'quality': video.quality.toString(),
        'url': video.url.toString(),
        'originalUrl': video.originalUrl.toString(),
      },
    )
    .toList();

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kover/database/app_database.dart';
import 'package:kover/models/enums/age_rating.dart';
import 'package:kover/models/enums/format.dart';
import 'package:kover/models/enums/library_type.dart';
import 'package:kover/models/enums/publication_status.dart';

void main() {
  late AppDatabase database;

  setUp(() {
    database = AppDatabase(
      DatabaseConnection(
        NativeDatabase.memory(),
        closeStreamsSynchronously: true,
      ),
    );
  });

  tearDown(() async {
    await database.close();
  });

  Future<void> insertLibrary(int id) async {
    await database
        .into(database.libraries)
        .insert(
          LibrariesCompanion.insert(
            id: Value(id),
            name: 'lib$id',
            type: LibraryType.manga,
          ),
        );
  }

  Future<void> insertSeries(int id) async {
    await database
        .into(database.series)
        .insert(
          SeriesCompanion(
            id: Value(id),
            libraryId: const Value(1),
            name: Value('name$id'),
            format: const Value(Format.epub),
            created: Value(DateTime.now()),
          ),
        );
  }

  Future<void> insertChapter(
    int id, {
    required int seriesId,
    required Format format,
    int remotePagesRead = 5,
    DateTime? remoteLastRead,
  }) async {
    await database
        .into(database.chapters)
        .insert(
          ChaptersCompanion.insert(
            id: Value(id),
            volumeId: 0,
            seriesId: seriesId,
            format: format,
            minNumber: 0,
            maxNumber: 0,
            sortOrder: 0,
            pages: 10,
            wordCount: 0,
            ageRating: AgeRating.unknown,
            releaseDate: DateTime.now(),
            publicationStatus: PublicationStatus.unknown,
            created: DateTime.now(),
            lastModified: DateTime.now(),
            remotePagesRead: Value(remotePagesRead),
            remoteLastRead: Value.absentIfNull(remoteLastRead),
          ),
        );
  }

  Future<void> insertProgress(
    int chapterId, {
    required int seriesId,
    required bool partial,
    String? bookScrollId,
    DateTime? lastModified,
  }) async {
    await database
        .into(database.readingProgress)
        .insert(
          ReadingProgressCompanion.insert(
            chapterId: Value(chapterId),
            volumeId: 0,
            seriesId: seriesId,
            libraryId: 1,
            pagesRead: const Value(5),
            bookScrollId: Value(bookScrollId),
            partial: Value(partial),
            lastModified: Value(lastModified ?? DateTime.now()),
          ),
        );
  }

  group('getOutdatedChapterIds', () {
    setUp(() async {
      await insertLibrary(1);
      await insertSeries(1);
    });

    test('includes partial epub progress during full sync', () async {
      final remoteLastRead = DateTime.now().subtract(const Duration(hours: 1));

      await insertChapter(
        1,
        seriesId: 1,
        format: Format.epub,
        remoteLastRead: remoteLastRead,
      );
      await insertChapter(
        2,
        seriesId: 1,
        format: Format.epub,
        remoteLastRead: remoteLastRead,
      );
      await insertChapter(
        3,
        seriesId: 1,
        format: Format.image,
        remoteLastRead: remoteLastRead,
      );
      await insertChapter(
        4,
        seriesId: 1,
        format: Format.epub,
        remoteLastRead: remoteLastRead,
      );

      await insertProgress(1, seriesId: 1, partial: true);
      await insertProgress(
        2,
        seriesId: 1,
        partial: false,
        bookScrollId: '//xpath',
      );
      await insertProgress(3, seriesId: 1, partial: true);

      final result = await database.readerDao.getOutdatedChapterIds();

      expect(result.toSet(), equals({1, 4}));
    });

    test('excludes partial epub progress when only missing', () async {
      final remoteLastRead = DateTime.now().subtract(const Duration(hours: 1));

      await insertChapter(
        1,
        seriesId: 1,
        format: Format.epub,
        remoteLastRead: remoteLastRead,
      );
      await insertChapter(
        2,
        seriesId: 1,
        format: Format.epub,
        remoteLastRead: remoteLastRead,
      );

      await insertProgress(1, seriesId: 1, partial: true);

      final result = await database.readerDao.getOutdatedChapterIds(
        onlyMissing: true,
      );

      expect(result, equals([2]));
    });
  });
}

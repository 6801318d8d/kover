import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:kover/api/openapi.swagger.dart';
import 'package:kover/mapping/dto/chapter_dto_mappings.dart';

void main() {
  ChapterDto chapter({
    required int pagesRead,
    MangaFormat format = MangaFormat.epub,
  }) {
    return ChapterDto(
      id: 1,
      volumeId: 2,
      minNumber: 1,
      maxNumber: 1,
      pages: 10,
      format: format,
      pagesRead: pagesRead,
      lastReadingProgressUtc: DateTime.utc(2024, 1, 1),
    );
  }

  group('ChapterDtoMappings', () {
    test('composes partial progress for chapters with read pages', () {
      final companion = chapter(pagesRead: 5).toChapterCompanions();
      final progress = companion.progress;

      expect(progress, isNotNull);
      expect(progress!.chapterId.value, 1);
      expect(progress.volumeId.value, 2);
      expect(progress.pagesRead.value, 5);
      expect(progress.lastModified.value, DateTime.utc(2024, 1, 1));
      expect(progress.partial.value, isTrue);
      expect(progress.dirty.value, isFalse);
    });

    test('does not compose progress for unread chapters', () {
      final companion = chapter(pagesRead: 0).toChapterCompanions();

      expect(companion.progress, isNull);
    });

    test('only marks EPUB progress as partial', () {
      final companion = chapter(
        pagesRead: 5,
        format: MangaFormat.image,
      ).toChapterCompanions();

      expect(companion.progress?.partial.value, isFalse);
    });

    test('keeps progress when replacing the series id', () {
      final companion = chapter(
        pagesRead: 5,
      ).toChapterCompanions().replace(seriesId: const Value(3));

      expect(companion.progress?.seriesId.value, 3);
    });
  });
}

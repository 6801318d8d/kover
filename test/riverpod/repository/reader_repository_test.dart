import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kover/database/app_database.dart';
import 'package:kover/database/dao/reader_dao.dart';
import 'package:kover/riverpod/repository/reader_repository.dart';
import 'package:kover/sync/reader_sync_operations.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';

@GenerateNiceMocks([
  MockSpec<AppDatabase>(),
  MockSpec<ReaderDao>(),
  MockSpec<ReaderSyncOperations>(),
])
import 'reader_repository_test.mocks.dart';

void main() {
  late MockAppDatabase mockDb;
  late MockReaderDao mockReaderDao;
  late MockReaderSyncOperations mockReaderClient;

  setUp(() {
    mockDb = MockAppDatabase();
    mockReaderDao = MockReaderDao();
    mockReaderClient = MockReaderSyncOperations();

    when(mockDb.readerDao).thenReturn(mockReaderDao);
  });

  group('progress sync', () {
    test('fetches when newer progress', () async {
      final repo = ReaderRepository(
        db: mockDb,
        readerClient: mockReaderClient,
      );

      final now = DateTime.now();
      final yesterday = now.subtract(const Duration(days: 1));

      final expected = ReadingProgressCompanion(
        chapterId: const Value(1),
        volumeId: const Value(1),
        seriesId: const Value(1),
        libraryId: const Value(1),
        pagesRead: const Value(10),
        bookScrollId: const Value('scrollId'),
        totalReads: const Value(1),
        created: Value(yesterday),
        lastModified: Value(now),
      );

      when(
        mockReaderDao.getOutdatedChapterIds(),
      ).thenAnswer((_) async => [1]);
      when(mockReaderClient.getProgress(1)).thenAnswer((_) async => expected);

      await repo.refreshOutdatedProgress();

      verify(mockReaderDao.mergeProgressBatch([expected])).called(1);
    });

    test('ensureSeriesProgress only fetches never-fetched chapters', () async {
      final repo = ReaderRepository(
        db: mockDb,
        readerClient: mockReaderClient,
      );

      final expected = const ReadingProgressCompanion(
        chapterId: Value(1),
        seriesId: Value(1),
        pagesRead: Value(10),
      );

      when(
        mockReaderDao.getOutdatedChapterIds(
          seriesId: 1,
          onlyMissing: true,
        ),
      ).thenAnswer((_) async => [1]);
      when(mockReaderClient.getProgress(1)).thenAnswer((_) async => expected);

      await repo.ensureSeriesProgress(seriesId: 1);

      verify(
        mockReaderDao.getOutdatedChapterIds(seriesId: 1, onlyMissing: true),
      ).called(1);
      verify(mockReaderDao.mergeProgressBatch([expected])).called(1);
    });

    test('refreshProgress merges the server progress', () async {
      final repo = ReaderRepository(
        db: mockDb,
        readerClient: mockReaderClient,
      );

      final remote = ReadingProgressCompanion(
        chapterId: const Value(1),
        seriesId: const Value(1),
        pagesRead: const Value(10),
        bookScrollId: const Value('scrollId'),
        lastModified: Value(DateTime.now()),
      );

      when(mockReaderClient.getProgress(1)).thenAnswer((_) async => remote);

      await repo.refreshProgress(1);

      verify(mockReaderDao.mergeProgressBatch([remote])).called(1);
    });

    test(
      'refreshProgress skips when neither the server nor the device has progress',
      () async {
        final repo = ReaderRepository(
          db: mockDb,
          readerClient: mockReaderClient,
        );

        final remote = ReadingProgressCompanion(
          chapterId: const Value(1),
          pagesRead: const Value(0),
          lastModified: Value(DateTime.utc(1)),
        );

        when(mockReaderClient.getProgress(1)).thenAnswer((_) async => remote);
        when(mockReaderDao.getProgress(1)).thenAnswer((_) async => null);

        await repo.refreshProgress(1);

        verifyNever(mockReaderDao.mergeProgressBatch(any));
      },
    );

    test('refreshProgress keeps local progress when the fetch fails', () async {
      final repo = ReaderRepository(
        db: mockDb,
        readerClient: mockReaderClient,
      );

      when(mockReaderClient.getProgress(1)).thenThrow(Exception('offline'));

      await repo.refreshProgress(1);

      verifyNever(mockReaderDao.mergeProgressBatch(any));
    });

    test('refreshProgress gives up after the timeout', () async {
      final repo = ReaderRepository(
        db: mockDb,
        readerClient: mockReaderClient,
      );

      when(
        mockReaderClient.getProgress(1),
      ).thenAnswer((_) => Completer<ReadingProgressCompanion>().future);

      await repo.refreshProgress(1, timeout: const Duration(milliseconds: 10));

      verifyNever(mockReaderDao.mergeProgressBatch(any));
    });
  });
}

class ReaderProgressCompanion {}

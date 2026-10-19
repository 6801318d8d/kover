import 'package:flutter_test/flutter_test.dart';
import 'package:kover/api/openapi.swagger.dart';
import 'package:kover/mapping/dto/progress_dto_mappings.dart';

void main() {
  test('full progress is not marked as partial', () {
    const dto = ProgressDto(
      volumeId: 1,
      chapterId: 2,
      pageNum: 5,
      seriesId: 3,
      libraryId: 4,
      bookScrollId: '//xpath',
    );

    final companion = dto.toReadingProgressCompanion();

    expect(companion.partial.value, isFalse);
    expect(companion.dirty.value, isFalse);
  });
}

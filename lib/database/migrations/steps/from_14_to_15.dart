import 'package:drift/drift.dart';
import 'package:kover/database/app_database.dart';
import 'package:kover/database/app_database.steps.dart';

Future<void> migrateFrom14To15(
  AppDatabase db,
  Migrator m,
  Schema15 schema,
) async {
  await m.addColumn(schema.readingProgress, schema.readingProgress.partial);
}

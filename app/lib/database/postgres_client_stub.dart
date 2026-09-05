import '../config.dart';
import 'postgres_client.dart';

PostgresClient createPostgresClient({
  required EfelantConfig config,
  required String deviceId,
}) {
  throw UnsupportedError('no postgres backend for this platform');
}

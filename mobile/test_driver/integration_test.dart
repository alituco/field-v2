import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  timeout: const Duration(minutes: 10),
  writeResponseOnFailure: true,
  responseDataCallback: (data) =>
      writeResponseData(data, destinationDirectory: 'build/e2e-artifacts'),
);

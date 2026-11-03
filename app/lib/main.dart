import 'data/savings_policy_api.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'data/session_owner.dart';
import 'data/supabase_auth_port.dart';
import 'data/security_api.dart';

import 'config/app_config.dart';
import 'data/auth_repository.dart';
import 'data/banking_api.dart';
import 'data/identity_api.dart';
import 'data/reference_photo_source.dart';
import 'data/profile_api.dart';
import 'nene_app.dart';
import 'session_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final authClient = http.Client();
  try {
    final photos = DeviceReferencePhotoSource();
    await photos.discardLostCapture();
    final config = AppConfig.fromEnvironment();
    final owner = SessionOwner(
      SupabaseAuthPort(
        authOrigin: config.supabaseUrl,
        client: authClient,
        publishableKey: config.supabasePublishableKey,
      ),
    );
    final auth = OwnedAuthRepository(owner);
    final httpClient = http.Client();
    final controller = SessionController(
      auth: auth,
      profiles: ProfileApi(baseUrl: config.apiBaseUrl, client: httpClient),
    );
    runApp(
      NeneApp(
        controller: controller,
        savingsPolicy: SavingsPolicyApi(
          baseUrl: config.apiBaseUrl,
          client: httpClient,
        ),
        security: SecurityApi(
          baseUrl: config.apiBaseUrl,
          client: httpClient,
          owner: owner,
        ),
        banking: BankingApi(baseUrl: config.apiBaseUrl, client: httpClient),
        identity: IdentityApi(baseUrl: config.apiBaseUrl, client: httpClient),
        photos: photos,
        onDispose: () {
          auth.dispose();
          httpClient.close();
          authClient.close();
        },
      ),
    );
  } catch (_) {
    authClient.close();
    // Invalid/missing configuration fails closed, without leaking values.
    runApp(const NeneApp());
  }
}

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config/app_config.dart';
import 'data/auth_repository.dart';
import 'data/bounded_auth_client.dart';
import 'data/profile_api.dart';
import 'nene_app.dart';
import 'session_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final authClient = BoundedAuthClient();
  try {
    final config = AppConfig.fromEnvironment();
    await Supabase.initialize(
      url: config.supabaseUrl.toString(),
      publishableKey: config.supabasePublishableKey,
      httpClient: authClient,
      debug: false,
      authOptions: const FlutterAuthClientOptions(
        persistSession: false,
        detectSessionInUri: false,
      ),
    );
    final httpClient = http.Client();
    final controller = SessionController(
      auth: SupabaseAuthRepository(Supabase.instance.client),
      profiles: ProfileApi(baseUrl: config.apiBaseUrl, client: httpClient),
    );
    runApp(
      NeneApp(
        controller: controller,
        onDispose: () {
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

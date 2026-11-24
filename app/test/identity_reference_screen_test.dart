import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nene_app/data/identity_repository.dart';
import 'package:nene_app/nene_app.dart';
import 'package:nene_app/session_controller.dart';
import 'package:nene_app/ui/identity_reference_screen.dart';
import 'package:nene_app/ui/nene_brand.dart';

import 'identity_test_doubles.dart';
import 'test_doubles.dart';

const captureKey = ValueKey('identity-capture-boundary');
final captureUi = Platform.environment['NENE_CAPTURE_UI'] == '1';

ThemeData testTheme() {
  final theme = neneTheme();
  return captureUi
      ? theme.copyWith(
          textTheme: theme.textTheme.apply(fontFamily: 'NeneTestRoboto'),
          filledButtonTheme: FilledButtonThemeData(
            style: theme.filledButtonTheme.style!.copyWith(
              textStyle: const WidgetStatePropertyAll(
                TextStyle(
                  fontFamily: 'NeneTestRoboto',
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        )
      : theme;
}

Future<void> settlePhoto(WidgetTester tester) async {
  for (var attempt = 0; attempt < 30; attempt++) {
    await tester.pump();
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    if (find.byType(LinearProgressIndicator).evaluate().isEmpty &&
        find.byType(CircularProgressIndicator).evaluate().isEmpty) {
      break;
    }
  }
  await tester.pumpAndSettle();
}

Future<void> tap(WidgetTester tester, String text) async {
  await tester.pump();
  final target = find.text(text);
  await tester.ensureVisible(target);
  await tester.pump();
  await tester.tap(target);
  await settlePhoto(tester);
}

Future<void> capture(WidgetTester tester, String name) async {
  if (!captureUi) return;
  for (final element in find.byType(Image).evaluate()) {
    final widget = element.widget as Image;
    await tester.runAsync(() => precacheImage(widget.image, element));
  }
  await tester.pumpAndSettle();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(captureKey),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('../.tmp/identity-ui/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUpAll(() async {
    if (!captureUi) return;
    final sdk = Platform.environment['FLUTTER_ROOT'] ?? '../.tools/flutter';
    final font = FontLoader('NeneTestRoboto')
      ..addFont(
        File(
          '$sdk/bin/cache/artifacts/material_fonts/roboto-regular.ttf',
        ).readAsBytes().then(ByteData.sublistView),
      );
    final icons = FontLoader('MaterialIcons')
      ..addFont(
        File(
          '$sdk/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
        ).readAsBytes().then(ByteData.sublistView),
      );
    await font.load();
    await icons.load();
  });
  late FakeAuth auth;
  late FakeProfiles profiles;
  late SessionController session;
  late FakeIdentity repository;
  late FakePhotos photos;

  setUp(() {
    auth = FakeAuth();
    profiles = FakeProfiles();
    session = SessionController(auth: auth, profiles: profiles);
    repository = FakeIdentity();
    photos = FakePhotos();
  });

  Future<void> mount(
    WidgetTester tester, {
    bool officer = false,
    double scale = 1,
  }) async {
    if (officer) {
      profiles.fetch = (_) async => officerProfile;
      repository.value = IdentitySummary.fromJson(
        identityJson(
          status: 'submitted',
          version: 3,
          customerId: 'customer-id',
        ),
      );
    }
    await session.signIn('demo@example.test', 'synthetic-password');
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: testTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: RepaintBoundary(
          key: captureKey,
          child: Scaffold(
            appBar: AppBar(title: const NeneLogo(size: 30)),
            body: IdentityReferenceScreen(
              session: session,
              repository: repository,
              photos: photos,
              customerId: officer ? 'customer-id' : null,
            ),
          ),
        ),
      ),
    );
    await settlePhoto(tester);
  }

  tearDown(() async {
    session.dispose();
    await auth.events.close();
  });

  testWidgets(
    'customer capture preview, retake, private save and submit stay distinct',
    (tester) async {
      await mount(tester);
      final start = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Start reference'),
      );
      expect(start.onPressed, isNull);
      await tap(
        tester,
        'I understand this notice and agree to submit an agreed test image.',
      );
      await tap(tester, 'Start reference');
      await tap(tester, 'Take photo');
      expect(find.text('Photo preview · not uploaded'), findsOneWidget);
      expect(repository.uploadKeys, isEmpty);
      expect(find.text('Submit reference'), findsNothing);
      await tap(tester, 'Retake photo');
      await tap(tester, 'Save photo privately');
      expect(find.text('Private reference photo'), findsOneWidget);
      await tap(tester, 'Submit reference');
      expect(find.text('Awaiting officer review'), findsOneWidget);
      expect(find.text('Accept reference'), findsNothing);
      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, 1500),
      );
      await tester.pumpAndSettle();
      await capture(tester, 'customer-submitted-390');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'officer requires confirmation, reviews exact customer and accepts reference only',
    (tester) async {
      await mount(tester, officer: true);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Accept reference'),
            )
            .onPressed,
        isNull,
      );
      await capture(tester, 'officer-review-top-390');
      await tap(
        tester,
        'I confirm this reference belongs to the selected customer I assisted.',
      );
      await tester.ensureVisible(find.text('Accept reference'));
      await capture(tester, 'officer-review-actions-390');
      await tap(tester, 'Accept reference');
      expect(
        find.textContaining('Accept reference for Demo Student, revision 1?'),
        findsOneWidget,
      );
      expect(repository.reviewActions, isEmpty);
      await tap(tester, 'Confirm review decision');
      expect(repository.reviewActions, ['accept_reference']);
      expect(find.text('Reference accepted'), findsOneWidget);
      expect(find.textContaining('does not complete eKYC'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'officer correction and 200 percent text remain operable on a narrow phone',
    (tester) async {
      await mount(tester, officer: true, scale: 2);
      await capture(tester, 'officer-review-390-text200');
      final reason = find.byType(TextField);
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      addTearDown(tester.view.resetViewInsets);
      await tester.ensureVisible(reason);
      await tester.enterText(reason, 'Please provide a clearer photo.');
      await tester.ensureVisible(find.text('Request correction'));
      await tester.pump();
      await capture(tester, 'officer-review-actions-390-text200-keyboard');
      await tap(tester, 'Request correction');
      await tap(tester, 'Confirm review decision');
      expect(repository.reviewActions, ['request_changes']);
      expect(find.text('Changes requested'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'sign out removes reference preview and inline review confirmation',
    (tester) async {
      auth.userId = 'user-id';
      auth.accessToken = 'test-token';
      profiles.fetch = (_) async => officerProfile;
      repository.value = IdentitySummary.fromJson(
        identityJson(
          status: 'submitted',
          version: 3,
          customerId: 'customer-id',
        ),
      );
      await tester.pumpWidget(
        NeneApp(
          controller: session,
          banking: FakeBanking(),
          identity: repository,
          photos: photos,
        ),
      );
      await settlePhoto(tester);
      await tap(tester, 'Find a customer');
      await tester.enterText(find.byType(TextField), 'New');
      await tap(tester, 'Search customers');
      await tap(tester, 'View customer');
      await tap(tester, 'Assist / review reference');
      await tap(
        tester,
        'I confirm this reference belongs to the selected customer I assisted.',
      );
      await tap(tester, 'Accept reference');
      await tester.tap(find.byTooltip('Sign out'));
      await tester.pumpAndSettle();
      expect(find.text('Welcome back'), findsOneWidget);
      expect(find.text('Confirm review decision'), findsNothing);
      expect(find.text('Private reference photo'), findsNothing);
      // NeneApp owns and disposes the session.
      await tester.pumpWidget(const SizedBox());
      session = SessionController(auth: auth, profiles: profiles);
    },
  );
}

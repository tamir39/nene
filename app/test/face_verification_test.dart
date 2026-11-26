// Face step before large same-bank and other-bank transfers, against fake
// HTTP replies that follow the face-check API contract. No face images are
// used: the photo source returns the synthetic reference fixture.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nene_app/data/banking_repository.dart';
import 'package:nene_app/data/confirmation_api.dart';
import 'package:nene_app/data/face_check.dart';
import 'package:nene_app/data/security_api.dart';
import 'package:nene_app/data/session_owner.dart';
import 'package:nene_app/ui/confirmation_screen.dart';
import 'package:nene_app/ui/nene_brand.dart';

import 'confirmation_screen_test.dart' as fixture show review, json, tap;
import 'identity_test_doubles.dart';
import 'interbank_transfer_test.dart' as ib;
import 'security_screen_test.dart' show Port;

const _account = BankAccount(
  id: 'source',
  accountNumber: '100000000001',
  type: 'checking',
  currency: 'VND',
  balanceMinor: '90000000',
  status: 'active',
);
const _faceCheckId = '3f2b8c1e-7a4d-4e5f-9b6a-0c1d2e3f4a5b';
final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

class FakeLiveness implements LivenessCheck {
  FakeLiveness({this.available = true});
  @override
  final bool available;
  final results = <LivenessResult>[];
  final poses = <LivenessPose>[];
  @override
  Future<LivenessResult> check(LivenessPose pose, Uint8List bytes) async {
    poses.add(pose);
    return results.isEmpty ? LivenessResult.passed : results.removeAt(0);
  }
}

/// One multipart upload to `/me/face-checks`, decoded for assertions.
class Upload {
  Upload(http.Request request)
    : key = request.headers['Idempotency-Key'],
      contentType = request.headers['content-type'] ?? '',
      body = latin1.decode(request.bodyBytes);
  final String? key;
  final String contentType;
  final String body;
  String? field(String name) =>
      RegExp('name="$name"\r\n\r\n([^\r]*)\r\n').firstMatch(body)?.group(1);

  /// The selfie part's bytes, or null when the part or its type is wrong.
  String? get selfie {
    const header =
        'content-type: image/png\r\n'
        'content-disposition: form-data; name="selfie"; filename="selfie.png"\r\n\r\n';
    final start = body.indexOf(header);
    if (start < 0) return null;
    return body.substring(start + header.length, body.lastIndexOf('\r\n--'));
  }
}

http.Response matched() => fixture.json({
  'faceCheckId': _faceCheckId,
  'matched': true,
  'expiresAt': DateTime.now()
      .toUtc()
      .add(const Duration(minutes: 5))
      .toIso8601String(),
});
http.Response refused(String reason) => http.Response(
  jsonEncode({
    'matched': false,
    'reason': reason,
    'message': 'Face check did not pass.',
  }),
  422,
);

/// Fake backend for one transfer screen. [face] answers each upload in turn.
class Backend {
  Backend({
    this.interbank = false,
    this.required = true,
    List<FutureOr<http.Response> Function()>? face,
  }) : face = face ?? [matched];
  final bool interbank;

  /// The review's `faceCheckRequired`; null leaves the field out.
  final bool? required;
  final List<FutureOr<http.Response> Function()> face;
  final uploads = <Upload>[];
  final confirmations = <Map<String, dynamic>>[];
  http.Response Function(Map<String, dynamic> body)? confirmReply;
  var reviews = 0;

  Future<http.Response> handle(http.Request req) async {
    final path = req.url.path;
    if (path.endsWith('/me/face-checks')) {
      expect(req.method, 'POST');
      uploads.add(Upload(req));
      return face.removeAt(0)();
    }
    if (path.endsWith('/configuration')) {
      return fixture.json(
        interbank ? _interbankConfiguration() : {'enabled': true},
      );
    }
    if (path.endsWith('transfers/')) {
      return fixture.json({'transfers': <Map<String, dynamic>>[]});
    }
    if (path.endsWith('/security')) return fixture.json({'state': 'ready'});
    if (path.endsWith('/review')) {
      reviews++;
      final amount = (jsonDecode(req.body) as Map)['amountMinor'];
      return fixture.json({
        ...(interbank ? _interbankReview() : fixture.review()),
        'amountMinor': amount,
        'sufficientFunds': true,
        'executionAvailable': true,
        'faceCheckRequired': ?required,
      });
    }
    if (path.endsWith('/cancel')) return fixture.json({'state': 'cancelled'});
    expect(path, endsWith('/confirm'));
    final body = jsonDecode(req.body) as Map<String, dynamic>;
    confirmations.add(body);
    final reply = confirmReply;
    if (reply != null) return reply(body);
    return fixture.json(
      interbank
          ? {...ib.posted(), 'receipt': _receipt()}
          : {
              'requestId': 'request',
              'revision': 2,
              'purpose': 'same-bank-transfer',
              'accessToken': 'test',
              'refreshToken': 'test',
              'state': 'posted',
              'sent': true,
              'executionAvailable': true,
              'replay': false,
            },
    );
  }
}

Map<String, dynamic> _interbankConfiguration() => ib.configuration();
Map<String, dynamic> _interbankReview() => {
  ...ib.review(),
  'amountMinor': '15000000',
};
Map<String, dynamic> _receipt() => {...ib.receipt(), 'amountMinor': '15000000'};

Future<SessionOwner> mount(
  WidgetTester tester,
  Backend backend, {
  FakeLiveness? liveness,
  FakePhotos? photos,
  double width = 390,
  double textScale = 1,
  double height = 1400,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final owner = SessionOwner(Port());
  await owner.signIn('', '');
  addTearDown(owner.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: neneTheme(),
      debugShowCheckedModeBanner: false,
      home: RepaintBoundary(
        key: captureKey,
        child: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(
              size: Size(width, height),
              textScaler: TextScaler.linear(textScale),
            ),
            child: ConfirmationScreen(
              account: _account,
              api: ConfirmationApi(
                SecurityApi(
                  baseUrl: Uri.parse('http://localhost/api/v1/'),
                  client: MockClient(backend.handle),
                  owner: owner,
                ),
                sendMoney: true,
                interbank: backend.interbank,
              ),
              photos: photos ?? FakePhotos(),
              liveness: liveness ?? FakeLiveness(),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return owner;
}

Future<void> review(
  WidgetTester tester, {
  String amount = '15000000',
  bool interbank = false,
}) async {
  if (interbank) {
    await _select(tester);
    await tester.enterText(find.byType(TextField), amount);
  } else {
    await tester.enterText(find.byType(TextField).at(0), '100000000002');
    await tester.enterText(find.byType(TextField).at(1), amount);
  }
  await fixture.tap(tester, 'Review confirmation');
}

Future<void> _select(WidgetTester tester) =>
    ib.select(tester, 'Demo Bank A', 'Demo recipient A · 990000000001');

Future<void> confirmWithCode(WidgetTester tester, String label) async {
  await tester.enterText(find.byType(TextField), '123456');
  await fixture.tap(tester, label);
}

/// Wraps the mounted screen for gated UI captures.
const captureKey = ValueKey('face-capture');

Finder get _codeField => find.widgetWithText(TextField, 'Authenticator code');

void main() {
  for (final required in [null, false]) {
    testWidgets(
      '${required == null ? 'missing' : 'false'} faceCheckRequired goes straight to the code',
      (tester) async {
        final backend = Backend(required: required);
        await mount(tester, backend);
        await review(tester, amount: '100000');
        expect(find.text('Face check required'), findsNothing);
        expect(_codeField, findsOneWidget);
        await confirmWithCode(tester, 'Confirm and send demo funds');
        expect(backend.confirmations.single, {
          'reviewToken': 'synthetic-review',
          'code': '123456',
        });
        expect(backend.uploads, isEmpty);
        expect(find.textContaining('Demo transfer sent.'), findsOneWidget);
      },
    );
  }

  testWidgets(
    'success: two checked photos, one upload, then the code with faceCheckId',
    (tester) async {
      final backend = Backend();
      final liveness = FakeLiveness();
      final owner = await mount(tester, backend, liveness: liveness);
      await review(tester);
      expect(find.text('Face check required'), findsOneWidget);
      expect(_codeField, findsNothing);
      expect(find.text('Check confirmation status'), findsNothing);
      await fixture.tap(tester, 'Take photo 1');
      expect(backend.uploads, isEmpty);
      expect(find.text('Take photo 2'), findsOneWidget);
      expect(find.bySemanticsLabel('Done'), findsOneWidget);
      await fixture.tap(tester, 'Take photo 2');
      expect(liveness.poses, [LivenessPose.straight, LivenessPose.turned]);
      final upload = backend.uploads.single;
      expect(upload.contentType, startsWith('multipart/form-data'));
      expect(upload.key, matches(_uuid));
      expect(upload.field('reviewToken'), 'synthetic-review');
      expect(jsonDecode(upload.field('liveness')!), {
        'blink': true,
        'turn': true,
      });
      expect(upload.selfie, latin1.decode(referenceFixture));
      expect(find.text('Face check required'), findsNothing);
      expect(find.textContaining('Face check passed'), findsOneWidget);
      await confirmWithCode(tester, 'Confirm and send demo funds');
      expect(backend.confirmations.single, {
        'reviewToken': 'synthetic-review',
        'code': '123456',
        'faceCheckId': _faceCheckId,
      });
      expect(owner.session, isNotNull);
      expect(find.textContaining('Demo transfer sent.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('interbank transfers use the same face step', (tester) async {
    final backend = Backend(interbank: true);
    await mount(tester, backend);
    await review(tester, interbank: true);
    expect(find.text('Face check required'), findsOneWidget);
    await fixture.tap(tester, 'Take photo 1');
    await fixture.tap(tester, 'Take photo 2');
    await confirmWithCode(tester, 'Confirm simulated transfer');
    expect(backend.confirmations.single['faceCheckId'], _faceCheckId);
    expect(find.text('Simulated transfer complete'), findsOneWidget);
  });

  testWidgets('no face: device check refuses photo 1 without uploading', (
    tester,
  ) async {
    final backend = Backend();
    final liveness = FakeLiveness()
      ..results.addAll([LivenessResult.noFace, LivenessResult.eyesClosed]);
    await mount(tester, backend, liveness: liveness);
    await review(tester);
    await fixture.tap(tester, 'Take photo 1');
    expect(find.textContaining('No face was found in photo 1'), findsOneWidget);
    await fixture.tap(tester, 'Take photo 1');
    expect(find.textContaining('eyes look closed'), findsOneWidget);
    await fixture.tap(tester, 'Take photo 1');
    expect(find.text('Take photo 2'), findsOneWidget);
    expect(backend.uploads, isEmpty);
    liveness.results.add(LivenessResult.notTurned);
    await fixture.tap(tester, 'Take photo 2');
    expect(find.textContaining('not turned enough'), findsOneWidget);
    expect(backend.uploads, isEmpty);
    await fixture.tap(tester, 'Take photo 2');
    expect(backend.uploads, hasLength(1));
    expect(_codeField, findsOneWidget);
  });

  testWidgets('no face: server refusal explains and allows a retry', (
    tester,
  ) async {
    final backend = Backend(face: [() => refused('no_face'), matched]);
    await mount(tester, backend);
    await review(tester);
    await fixture.tap(tester, 'Take photo 1');
    await fixture.tap(tester, 'Take photo 2');
    expect(
      find.textContaining('No face was found in the photo.'),
      findsOneWidget,
    );
    expect(find.text('Attempts left for this review: 4'), findsOneWidget);
    expect(_codeField, findsNothing);
    await fixture.tap(tester, 'Try the face check again');
    expect(find.text('Take photo 2'), findsOneWidget);
    await fixture.tap(tester, 'Take photo 2');
    expect(_codeField, findsOneWidget);
  });

  testWidgets(
    'not matched, then retry with new photos and a new key succeeds',
    (tester) async {
      final backend = Backend(face: [() => refused('not_matched'), matched]);
      await mount(tester, backend);
      await review(tester);
      await fixture.tap(tester, 'Take photo 1');
      await fixture.tap(tester, 'Take photo 2');
      expect(
        find.textContaining('did not match your reference photo'),
        findsOneWidget,
      );
      await fixture.tap(tester, 'Try the face check again');
      await fixture.tap(tester, 'Take photo 2');
      expect(backend.uploads, hasLength(2));
      expect(backend.uploads[0].key, isNot(backend.uploads[1].key));
      await confirmWithCode(tester, 'Confirm and send demo funds');
      expect(backend.confirmations.single['faceCheckId'], _faceCheckId);
    },
  );

  testWidgets('five failed checks stop the step for this review', (
    tester,
  ) async {
    final backend = Backend(
      face: [
        () => refused('not_matched'),
        () => refused('multiple_faces'),
        () => refused('not_matched'),
        () => refused('no_face'),
        () => refused('not_matched'),
      ],
    );
    await mount(tester, backend);
    await review(tester);
    for (var attempt = 0; attempt < maximumFaceCheckFailures; attempt++) {
      await fixture.tap(
        tester,
        attempt == 0 ? 'Take photo 1' : 'Try the face check again',
      );
      await fixture.tap(tester, 'Take photo 2');
    }
    expect(find.textContaining('Too many face checks'), findsOneWidget);
    expect(find.text('Try the face check again'), findsNothing);
    expect(find.text('Take photo 1'), findsNothing);
    expect(_codeField, findsNothing);
    expect(backend.uploads, hasLength(5));
    await fixture.tap(tester, 'Edit details / new review');
    expect(find.text('Review confirmation'), findsOneWidget);
  });

  testWidgets('an unknown outcome resends the same photo and key', (
    tester,
  ) async {
    final backend = Backend(face: [() => http.Response('{}', 503), matched]);
    final owner = await mount(tester, backend);
    await review(tester);
    await fixture.tap(tester, 'Take photo 1');
    await fixture.tap(tester, 'Take photo 2');
    expect(find.textContaining('did not finish'), findsOneWidget);
    expect(owner.session, isNotNull);
    await fixture.tap(tester, 'Send the same photo again');
    expect(backend.uploads, hasLength(2));
    expect(backend.uploads[1].key, backend.uploads[0].key);
    expect(backend.uploads[1].selfie, backend.uploads[0].selfie);
    expect(backend.uploads[1].field('liveness'), '{"blink":true,"turn":true}');
    expect(_codeField, findsOneWidget);
  });

  testWidgets('server stop reasons end the step without signing out', (
    tester,
  ) async {
    final backend = Backend(face: [() => http.Response('{}', 409)]);
    final owner = await mount(tester, backend);
    await review(tester);
    await fixture.tap(tester, 'Take photo 1');
    await fixture.tap(tester, 'Take photo 2');
    expect(
      find.textContaining('A face check is not possible for this review'),
      findsOneWidget,
    );
    expect(find.text('Try the face check again'), findsNothing);
    expect(owner.session, isNotNull);
  });

  testWidgets('web and desktop skip the device photos', (tester) async {
    final backend = Backend();
    final liveness = FakeLiveness(available: false);
    await mount(tester, backend, liveness: liveness);
    await review(tester);
    expect(
      find.textContaining('Head-movement checks run only'),
      findsOneWidget,
    );
    expect(find.text('Take photo 1'), findsNothing);
    await fixture.tap(tester, 'Take or choose a photo');
    expect(liveness.poses, isEmpty);
    expect(jsonDecode(backend.uploads.single.field('liveness')!), {
      'blink': false,
      'turn': false,
    });
    await confirmWithCode(tester, 'Confirm and send demo funds');
    expect(backend.confirmations.single['faceCheckId'], _faceCheckId);
  });

  testWidgets(
    '409 FACE_CHECK_REQUIRED keeps the session and asks for a face check',
    (tester) async {
      final backend = Backend(required: false);
      backend.confirmReply = (body) => body['faceCheckId'] == null
          ? http.Response(
              jsonEncode({
                'code': 'FACE_CHECK_REQUIRED',
                'message': 'Face check required.',
              }),
              409,
            )
          : http.Response(
              jsonEncode({
                'requestId': 'request',
                'revision': 2,
                'purpose': 'same-bank-transfer',
                'accessToken': 'test',
                'refreshToken': 'test',
                'state': 'posted',
                'sent': true,
                'executionAvailable': true,
                'replay': false,
              }),
              200,
            );
      final owner = await mount(tester, backend);
      await review(tester);
      expect(_codeField, findsOneWidget);
      await confirmWithCode(tester, 'Confirm and send demo funds');
      expect(owner.session, isNotNull);
      expect(find.textContaining('No money was sent.'), findsOneWidget);
      expect(find.text('Face check required'), findsOneWidget);
      expect(find.textContaining('unconfirmed'), findsNothing);
      await fixture.tap(tester, 'Take photo 1');
      await fixture.tap(tester, 'Take photo 2');
      await confirmWithCode(tester, 'Confirm and send demo funds');
      expect(backend.confirmations, hasLength(2));
      expect(backend.confirmations.last['faceCheckId'], _faceCheckId);
      expect(find.textContaining('Demo transfer sent.'), findsOneWidget);
    },
  );

  testWidgets('an expired face check asks for a new one', (tester) async {
    final backend = Backend();
    await mount(tester, backend);
    await review(tester);
    await fixture.tap(tester, 'Take photo 1');
    await fixture.tap(tester, 'Take photo 2');
    expect(_codeField, findsOneWidget);
    await tester.pump(const Duration(minutes: 5, seconds: 1));
    await tester.pumpAndSettle();
    expect(_codeField, findsNothing);
    expect(find.textContaining('face check expired'), findsOneWidget);
    expect(find.text('Take photo 1'), findsOneWidget);
  });

  testWidgets('transfer amounts show the face-check hint and 50M cap', (
    tester,
  ) async {
    final backend = Backend();
    await mount(tester, backend);
    expect(
      find.text(
        'Whole VND only · up to 50,000,000 VND. Over 10,000,000 VND, or over 20,000,000 VND in a day, needs a face check',
      ),
      findsOneWidget,
    );
    await review(tester, amount: '50000001');
    expect(
      find.text('Each transfer can be at most 50,000,000 VND.'),
      findsOneWidget,
    );
    expect(backend.reviews, 0);
    await review(tester, amount: '50000000');
    expect(backend.reviews, 1);
  });

  testWidgets('face step fits 320 px at 2x text', (tester) async {
    final backend = Backend(face: [() => refused('not_matched'), matched]);
    await mount(tester, backend, width: 320, textScale: 2);
    await review(tester);
    expect(find.text('Face check required'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await fixture.tap(tester, 'Take photo 1');
    expect(tester.takeException(), isNull);
    await fixture.tap(tester, 'Take photo 2');
    expect(find.text('Try the face check again'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await fixture.tap(tester, 'Try the face check again');
    await fixture.tap(tester, 'Take photo 2');
    expect(_codeField, findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

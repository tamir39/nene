import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nene_app/data/face_check.dart';
import 'package:nene_app/data/face_check_mlkit.dart';

import 'identity_test_doubles.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('google_mlkit_face_detector');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  group('classifyFaces', () {
    const photo = Size(1000, 800);

    test('needs exactly one face', () {
      expect(classifyFaces([], photo), FaceCheckResult.noFace);
      expect(
        classifyFaces([
          const Rect.fromLTWH(0, 0, 300, 300),
          const Rect.fromLTWH(500, 0, 300, 300),
        ], photo),
        FaceCheckResult.multipleFaces,
      );
    });

    test('face box must cover 20 percent of the shorter photo side', () {
      expect(
        classifyFaces([const Rect.fromLTWH(100, 100, 160, 200)], photo),
        FaceCheckResult.oneFace,
      );
      expect(
        classifyFaces([const Rect.fromLTWH(100, 100, 159, 400)], photo),
        FaceCheckResult.faceTooSmall,
      );
    });
  });

  test('only detector gaps and one clear face allow upload', () {
    expect(FaceCheckResult.values.where((result) => result.allowsUpload), [
      FaceCheckResult.oneFace,
      FaceCheckResult.unavailable,
      FaceCheckResult.failed,
    ]);
  });

  test(
    'ML Kit adapter sends decoded pixels and classifies the reply',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return call.method == 'vision#startFaceDetector'
            ? [
                {
                  'rect': {'left': 40, 'top': 30, 'right': 120, 'bottom': 130},
                  'landmarks': <String, dynamic>{},
                  'contours': <String, dynamic>{},
                },
              ]
            : null;
      });
      expect(
        await const MlKitFaceCheck().check(referenceFixture),
        FaceCheckResult.oneFace,
      );
      expect(calls.map((call) => call.method), [
        'vision#startFaceDetector',
        'vision#closeFaceDetector',
      ]);
      final image = (calls.first.arguments as Map)['imageData'] as Map;
      expect(image['type'], 'bitmap');
      expect(image['path'], isNull);
      expect((image['bitmapData'] as Uint8List).length, 160 * 160 * 4);
      expect((image['metadata'] as Map)['width'], 160);
      expect((image['metadata'] as Map)['height'], 160);
    },
  );

  test('ML Kit adapter reports detector problems without throwing', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'vision#startFaceDetector'
          ? throw PlatformException(code: 'InputImageConverterError')
          : null,
    );
    expect(
      await const MlKitFaceCheck().check(referenceFixture),
      FaceCheckResult.failed,
    );
    expect(
      await const MlKitFaceCheck().check(Uint8List.fromList([1, 2, 3])),
      FaceCheckResult.failed,
    );
  });

  group('classifyLiveness', () {
    FaceMeasurement face(double yaw, {double eyes = .9}) =>
        FaceMeasurement(yaw: yaw, leftEyeOpen: eyes, rightEyeOpen: eyes);

    test('needs exactly one measurable face', () {
      for (final pose in LivenessPose.values) {
        expect(classifyLiveness(pose, []), LivenessResult.noFace);
        expect(
          classifyLiveness(pose, [face(0), face(30)]),
          LivenessResult.multipleFaces,
        );
        expect(
          classifyLiveness(pose, [const FaceMeasurement()]),
          LivenessResult.failed,
        );
      }
      expect(
        classifyLiveness(LivenessPose.straight, [
          const FaceMeasurement(yaw: 0, leftEyeOpen: .9),
        ]),
        LivenessResult.failed,
      );
    });

    test('photo 1 looks straight, |yaw| < 12, with both eyes over 0.6', () {
      expect(
        classifyLiveness(LivenessPose.straight, [face(11.9)]),
        LivenessResult.passed,
      );
      expect(
        classifyLiveness(LivenessPose.straight, [face(-11.9)]),
        LivenessResult.passed,
      );
      expect(
        classifyLiveness(LivenessPose.straight, [face(12)]),
        LivenessResult.notStraight,
      );
      expect(
        classifyLiveness(LivenessPose.straight, [face(-25)]),
        LivenessResult.notStraight,
      );
      expect(
        classifyLiveness(LivenessPose.straight, [face(0, eyes: .6)]),
        LivenessResult.eyesClosed,
      );
      expect(
        classifyLiveness(LivenessPose.straight, [
          const FaceMeasurement(yaw: 0, leftEyeOpen: .9, rightEyeOpen: .2),
        ]),
        LivenessResult.eyesClosed,
      );
    });

    test('photo 2 turns the head, |yaw| > 20, either way', () {
      expect(
        classifyLiveness(LivenessPose.turned, [face(20.1)]),
        LivenessResult.passed,
      );
      expect(
        classifyLiveness(LivenessPose.turned, [face(-20.1, eyes: .1)]),
        LivenessResult.passed,
      );
      expect(
        classifyLiveness(LivenessPose.turned, [face(20)]),
        LivenessResult.notTurned,
      );
      expect(
        classifyLiveness(LivenessPose.turned, [face(-5)]),
        LivenessResult.notTurned,
      );
    });
  });

  test('ML Kit liveness asks for classification and reads pose', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'vision#startFaceDetector'
          ? [
              {
                'rect': {'left': 40, 'top': 30, 'right': 120, 'bottom': 130},
                'headEulerAngleY': -24.5,
                'leftEyeOpenProbability': .95,
                'rightEyeOpenProbability': .9,
                'landmarks': <String, dynamic>{},
                'contours': <String, dynamic>{},
              },
            ]
          : null;
    });
    const check = MlKitLivenessCheck();
    expect(check.available, isTrue);
    expect(
      await check.check(LivenessPose.turned, referenceFixture),
      LivenessResult.passed,
    );
    expect(
      await check.check(LivenessPose.straight, referenceFixture),
      LivenessResult.notStraight,
    );
    final options = (calls.first.arguments as Map)['options'] as Map;
    expect(options['enableClassification'], isTrue);
    expect(options['mode'], 'accurate');
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'vision#startFaceDetector'
          ? throw PlatformException(code: 'InputImageConverterError')
          : null,
    );
    expect(
      await check.check(LivenessPose.straight, referenceFixture),
      LivenessResult.failed,
    );
  });

  test('only Android and iOS use the ML Kit detector', () async {
    expect(createDeviceFaceCheck(), isA<MlKitFaceCheck>());
    expect(createDeviceLivenessCheck(), isA<MlKitLivenessCheck>());
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      expect(createDeviceFaceCheck(), isA<UnavailableFaceCheck>());
      expect(createDeviceLivenessCheck().available, isFalse);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
    expect(
      await const UnavailableFaceCheck().check(referenceFixture),
      FaceCheckResult.unavailable,
    );
  });
}

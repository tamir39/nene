import {
  Inject,
  Injectable,
  Logger,
  ServiceUnavailableException,
} from '@nestjs/common';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';
import type { InferenceSession, Tensor } from 'onnxruntime-node';
import { ENVIRONMENT } from '../config/config.module.js';
import type { Environment } from '../config/environment.js';
import { FaceMatcher, type FaceComparison } from './face-matcher.js';

type Ort = typeof import('onnxruntime-node');
type Models = {
  ort: Ort;
  detector: InferenceSession;
  recognizer: InferenceSession;
  antispoofV2: InferenceSession;
  antispoofV1: InferenceSession;
};
type Rgb = { data: Buffer; width: number; height: number };
type Face = {
  score: number;
  x: number;
  y: number;
  w: number;
  h: number;
  landmarks: [number, number][];
};
type Manifest = { models: { file: string; role: string; sha256: string }[] };

export const defaultFaceThreshold = 0.4;
// Detection follows the feasibility spike: YuNet at 640x640, score 0.6, NMS 0.3.
const detectSize = 640;
const detectScore = 0.6;
const nmsThreshold = 0.3;
// Faces narrower than 15 % of the short image side are background faces.
const minFaceFraction = 0.15;
const maxSide = 640;
// Bounds the wait behind the single-job mutex on a 0.1 CPU instance.
const maxQueued = 3;
const jobTimeoutMs = 40_000;
// ArcFace 112x112 landmark template used by OpenCV FaceRecognizerSF.alignCrop.
const template: [number, number][] = [
  [38.2946, 51.6963],
  [73.5318, 51.5014],
  [56.0252, 71.7366],
  [41.5493, 92.3655],
  [70.7299, 92.2041],
];

/** Backend root (backend/), from dist/face or .test-dist/src/face. */
function backendRoot() {
  const here = dirname(fileURLToPath(import.meta.url));
  return here.includes('.test-dist')
    ? join(here, '../../..')
    : join(here, '../..');
}

export function cosine(a: Float32Array, b: Float32Array) {
  let dot = 0,
    na = 0,
    nb = 0;
  for (let i = 0; i < a.length; i++) {
    dot += a[i]! * b[i]!;
    na += a[i]! * a[i]!;
    nb += b[i]! * b[i]!;
  }
  return dot / Math.sqrt(na * nb);
}

function iou(a: Face, b: Face) {
  const x1 = Math.max(a.x, b.x),
    y1 = Math.max(a.y, b.y);
  const x2 = Math.min(a.x + a.w, b.x + b.w),
    y2 = Math.min(a.y + a.h, b.y + b.h);
  const inter = Math.max(0, x2 - x1) * Math.max(0, y2 - y1);
  return inter / (a.w * a.h + b.w * b.h - inter);
}

/** 2-D similarity transform (Umeyama) mapping src onto dst: [a, b, tx, ty]. */
export function similarity(src: [number, number][], dst: [number, number][]) {
  const n = src.length;
  let sx = 0,
    sy = 0,
    dx = 0,
    dy = 0;
  for (let i = 0; i < n; i++) {
    sx += src[i]![0];
    sy += src[i]![1];
    dx += dst[i]![0];
    dy += dst[i]![1];
  }
  sx /= n;
  sy /= n;
  dx /= n;
  dy /= n;
  let num1 = 0,
    num2 = 0,
    den = 0;
  for (let i = 0; i < n; i++) {
    const px = src[i]![0] - sx,
      py = src[i]![1] - sy,
      qx = dst[i]![0] - dx,
      qy = dst[i]![1] - dy;
    num1 += px * qx + py * qy;
    num2 += px * qy - py * qx;
    den += px * px + py * py;
  }
  const a = num1 / den,
    b = num2 / den;
  return [a, b, dx - (a * sx - b * sy), dy - (b * sx + a * sy)] as const;
}

/**
 * Server-side face comparison: YuNet (MIT) detection, SFace fp32 (Apache-2.0)
 * embeddings with cosine similarity, and MiniFASNet V2 + V1SE (Apache-2.0)
 * passive anti-spoof as an advisory score only. Models load lazily behind one
 * shared promise and one comparison runs at a time, to fit a 512 MB instance.
 * Images are processed in memory and never written anywhere.
 */
@Injectable()
export class FaceMatchService extends FaceMatcher {
  private readonly logger = new Logger(FaceMatchService.name);
  private loading?: Promise<Models>;
  private queue: Promise<unknown> = Promise.resolve();
  private queued = 0;
  private readonly threshold: number;

  constructor(@Inject(ENVIRONMENT) env: Environment) {
    super();
    this.threshold = env.faceMatchThreshold ?? defaultFaceThreshold;
  }

  compare(selfie: Buffer, reference: Buffer): Promise<FaceComparison> {
    if (this.queued >= maxQueued)
      return Promise.reject(
        new ServiceUnavailableException(
          'Face verification is busy. Try again in a moment.',
        ),
      );
    this.queued++;
    const job = this.queue.then(() => this.run(selfie, reference));
    // Keep the queue alive after a failed job.
    this.queue = job.catch(() => undefined).finally(() => this.queued--);
    let timer: NodeJS.Timeout | undefined;
    // The caller stops waiting; the native job still finishes behind the mutex.
    const timeout = new Promise<never>((_, reject) => {
      timer = setTimeout(
        () =>
          reject(
            new ServiceUnavailableException(
              'Face verification took too long. Try again.',
            ),
          ),
        jobTimeoutMs,
      );
    });
    return Promise.race([job, timeout]).finally(() => clearTimeout(timer));
  }

  /** Loads and verifies the models once; a failed load is retried next time. */
  models(): Promise<Models> {
    this.loading ??= this.load().catch((error: unknown) => {
      this.loading = undefined;
      throw error;
    });
    return this.loading;
  }

  private async load(): Promise<Models> {
    const root = backendRoot();
    try {
      const manifest = JSON.parse(
        await readFile(join(root, 'face-models.json'), 'utf8'),
      ) as Manifest;
      const ort = await import('onnxruntime-node');
      const options: InferenceSession.SessionOptions = {
        intraOpNumThreads: 1,
        interOpNumThreads: 1,
        executionMode: 'sequential',
        graphOptimizationLevel: 'all',
        enableCpuMemArena: false,
        // Errors only: SFace's exporter leaves initializers in its graph inputs.
        logSeverityLevel: 3,
      };
      const session = async (file: string) => {
        const entry = manifest.models.find((m) => m.file === file);
        const bytes = await readFile(join(root, 'models', file));
        if (
          !entry ||
          createHash('sha256').update(bytes).digest('hex') !== entry.sha256
        )
          throw new Error(`Model ${file} is missing or does not match.`);
        return ort.InferenceSession.create(bytes, options);
      };
      sharp.cache(false);
      const models = {
        ort,
        detector: await session('yunet_2023mar.onnx'),
        recognizer: await session('sface_2021dec.onnx'),
        antispoofV2: await session('MiniFASNetV2.onnx'),
        antispoofV1: await session('MiniFASNetV1SE.onnx'),
      };
      this.logger.log('Face models loaded.');
      return models;
    } catch (error) {
      this.logger.error(
        `Face models are unavailable: ${error instanceof Error ? error.message : 'unknown error'}`,
      );
      throw new ServiceUnavailableException(
        'Face verification is temporarily unavailable.',
      );
    }
  }

  private async run(
    selfie: Buffer,
    reference: Buffer,
  ): Promise<FaceComparison> {
    const models = await this.models();
    const ref = await this.analyse(models, reference, false);
    if (ref.faces !== 1 || !ref.embedding)
      return { outcome: 'reference_unusable', score: null, antispoof: null };
    const own = await this.analyse(models, selfie, true);
    if (own.faces === 0)
      return { outcome: 'no_face', score: null, antispoof: null };
    if (own.faces > 1 || !own.embedding)
      return { outcome: 'multiple_faces', score: null, antispoof: null };
    const score = Math.round(cosine(own.embedding, ref.embedding) * 1e4) / 1e4;
    return {
      outcome: score >= this.threshold ? 'matched' : 'not_matched',
      score,
      antispoof: own.antispoof,
    };
  }

  private async analyse(models: Models, bytes: Buffer, antispoof: boolean) {
    const image = await decode(bytes);
    const minSide = Math.min(image.width, image.height);
    const faces = (await this.detect(models, image)).filter(
      (face) => face.w >= minFaceFraction * minSide,
    );
    if (faces.length !== 1)
      return { faces: faces.length, embedding: null, antispoof: null };
    const face = faces[0]!;
    const output = await models.recognizer.run({
      data: new models.ort.Tensor(
        'float32',
        align(image, face.landmarks),
        [1, 3, 112, 112],
      ),
    });
    const embedding = Float32Array.from(
      (output.fc1 as Tensor).data as Float32Array,
    );
    dispose(output);
    let real: number | null = null;
    if (antispoof) {
      // Silent-Face ensemble: V2 at crop scale 2.7 and V1SE at 4.0; class 1 = real.
      const v2 = await this.spoof(models, models.antispoofV2, image, face, 2.7);
      const v1 = await this.spoof(models, models.antispoofV1, image, face, 4.0);
      real = Math.round(((v2 + v1) / 2) * 1000) / 1000;
    }
    return { faces: 1, embedding, antispoof: real };
  }

  /** YuNet: BGR float 0..255, NCHW 640x640 with the image at the top left. */
  private async detect(models: Models, image: Rgb): Promise<Face[]> {
    const scale = Math.min(
      detectSize / image.width,
      detectSize / image.height,
      1,
    );
    const w = Math.round(image.width * scale),
      h = Math.round(image.height * scale);
    const source =
      scale === 1
        ? image.data
        : await sharp(image.data, {
            raw: { width: image.width, height: image.height, channels: 3 },
          })
            .resize(w, h, { fit: 'fill' })
            .raw()
            .toBuffer();
    const plane = detectSize * detectSize;
    const input = new Float32Array(3 * plane);
    for (let y = 0; y < h; y++)
      for (let x = 0; x < w; x++) {
        const s = (y * w + x) * 3,
          d = y * detectSize + x;
        input[d] = source[s + 2]!;
        input[plane + d] = source[s + 1]!;
        input[2 * plane + d] = source[s]!;
      }
    const out = await models.detector.run({
      input: new models.ort.Tensor('float32', input, [
        1,
        3,
        detectSize,
        detectSize,
      ]),
    });
    const faces: Face[] = [];
    for (const stride of [8, 16, 32]) {
      const cols = detectSize / stride;
      const cls = out[`cls_${stride}`]!.data as Float32Array,
        obj = out[`obj_${stride}`]!.data as Float32Array,
        box = out[`bbox_${stride}`]!.data as Float32Array,
        kps = out[`kps_${stride}`]!.data as Float32Array;
      for (let i = 0; i < cls.length; i++) {
        const score = Math.sqrt(
          Math.min(Math.max(cls[i]!, 0), 1) * Math.min(Math.max(obj[i]!, 0), 1),
        );
        if (score < detectScore) continue;
        const r = Math.floor(i / cols),
          c = i % cols;
        const cx = (c + box[i * 4]!) * stride,
          cy = (r + box[i * 4 + 1]!) * stride;
        const bw = Math.exp(box[i * 4 + 2]!) * stride,
          bh = Math.exp(box[i * 4 + 3]!) * stride;
        const landmarks: [number, number][] = [];
        for (let k = 0; k < 5; k++)
          landmarks.push([
            ((kps[i * 10 + 2 * k]! + c) * stride) / scale,
            ((kps[i * 10 + 2 * k + 1]! + r) * stride) / scale,
          ]);
        faces.push({
          score,
          x: (cx - bw / 2) / scale,
          y: (cy - bh / 2) / scale,
          w: bw / scale,
          h: bh / scale,
          landmarks,
        });
      }
    }
    dispose(out);
    faces.sort((a, b) => b.score - a.score);
    const kept: Face[] = [];
    for (const face of faces)
      if (kept.every((k) => iou(k, face) < nmsThreshold)) kept.push(face);
    return kept;
  }

  /** MiniFASNet: crop the box times `wanted`, resize to 80x80, BGR; returns P(real). */
  private async spoof(
    models: Models,
    session: InferenceSession,
    image: Rgb,
    face: Face,
    wanted: number,
  ) {
    const scale = Math.min(
      (image.height - 1) / face.h,
      (image.width - 1) / face.w,
      wanted,
    );
    const cx = face.x + face.w / 2,
      cy = face.y + face.h / 2;
    const x1 = Math.max(0, Math.floor(cx - (face.w * scale) / 2)),
      y1 = Math.max(0, Math.floor(cy - (face.h * scale) / 2));
    const x2 = Math.min(image.width - 1, Math.floor(cx + (face.w * scale) / 2)),
      y2 = Math.min(image.height - 1, Math.floor(cy + (face.h * scale) / 2));
    const crop = await sharp(image.data, {
      raw: { width: image.width, height: image.height, channels: 3 },
    })
      .extract({
        left: x1,
        top: y1,
        width: Math.max(1, x2 - x1 + 1),
        height: Math.max(1, y2 - y1 + 1),
      })
      .resize(80, 80, { fit: 'fill' })
      .raw()
      .toBuffer();
    const input = new Float32Array(3 * 6400);
    for (let i = 0; i < 6400; i++) {
      input[i] = crop[i * 3 + 2]!;
      input[6400 + i] = crop[i * 3 + 1]!;
      input[12800 + i] = crop[i * 3]!;
    }
    const out = await session.run({
      input: new models.ort.Tensor('float32', input, [1, 3, 80, 80]),
    });
    const logits = Array.from(out.output!.data as Float32Array);
    dispose(out);
    const max = Math.max(...logits);
    const exp = logits.map((x) => Math.exp(x - max));
    const sum = exp.reduce((p, q) => p + q, 0);
    return exp[1]! / sum;
  }
}

function dispose(output: InferenceSession.OnnxValueMapType) {
  for (const value of Object.values(output))
    (value as { dispose?: () => void }).dispose?.();
}

/** Auto-orients, downscales to 640 px and returns 3-channel sRGB bytes. */
async function decode(bytes: Buffer): Promise<Rgb> {
  const { data, info } = await sharp(bytes, { limitInputPixels: 4096 * 4096 })
    .rotate()
    .resize({
      width: maxSide,
      height: maxSide,
      fit: 'inside',
      withoutEnlargement: true,
    })
    .removeAlpha()
    .toColourspace('srgb')
    .raw()
    .toBuffer({ resolveWithObject: true });
  if (info.channels !== 3) throw new Error('Unexpected image channels.');
  return { data, width: info.width, height: info.height };
}

/** Warps the face to 112x112 with bilinear sampling; RGB float NCHW, unscaled. */
function align(image: Rgb, landmarks: [number, number][]) {
  const [a, b, tx, ty] = similarity(landmarks, template);
  const det = a * a + b * b;
  const plane = 112 * 112;
  const out = new Float32Array(3 * plane);
  const pixel = (x: number, y: number, ch: number) =>
    x < 0 || y < 0 || x >= image.width || y >= image.height
      ? 0
      : image.data[(y * image.width + x) * 3 + ch]!;
  for (let v = 0; v < 112; v++)
    for (let u = 0; u < 112; u++) {
      const qx = u - tx,
        qy = v - ty;
      const x = (a * qx + b * qy) / det,
        y = (-b * qx + a * qy) / det;
      const x0 = Math.floor(x),
        y0 = Math.floor(y),
        fx = x - x0,
        fy = y - y0;
      for (let ch = 0; ch < 3; ch++)
        out[ch * plane + v * 112 + u] =
          pixel(x0, y0, ch) * (1 - fx) * (1 - fy) +
          pixel(x0 + 1, y0, ch) * fx * (1 - fy) +
          pixel(x0, y0 + 1, ch) * (1 - fx) * fy +
          pixel(x0 + 1, y0 + 1, ch) * fx * fy;
    }
  return out;
}

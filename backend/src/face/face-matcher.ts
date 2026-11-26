/**
 * Result of comparing one selfie with the customer's accepted reference photo.
 * `score` is cosine similarity and `antispoof` the advisory passive anti-spoof
 * probability of a real capture. Neither value is ever returned to the client.
 */
export type FaceOutcome =
  | 'matched'
  | 'not_matched'
  | 'no_face'
  | 'multiple_faces'
  | 'reference_unusable';

export interface FaceComparison {
  outcome: FaceOutcome;
  score: number | null;
  antispoof: number | null;
}

/**
 * The matcher boundary. Production uses FaceMatchService (ONNX); tests replace
 * it with a fake so no real face images are needed.
 */
export abstract class FaceMatcher {
  abstract compare(selfie: Buffer, reference: Buffer): Promise<FaceComparison>;
}

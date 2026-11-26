// Downloads the face-check models listed in face-models.json into ./models and
// verifies each SHA-256. A mismatch or failed download exits non-zero, so a
// build that runs this first fails instead of deploying unverified models.
// Files that already match are kept; nothing is written outside ./models.
import { createHash } from 'node:crypto';
import { mkdir, readFile, rename, rm, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(fileURLToPath(import.meta.url));
const manifest = JSON.parse(
  await readFile(join(root, 'face-models.json'), 'utf8'),
);
const directory = join(root, 'models');
const sha256 = (bytes) => createHash('sha256').update(bytes).digest('hex');

async function existing(path) {
  try {
    return await readFile(path);
  } catch {
    return undefined;
  }
}

await mkdir(directory, { recursive: true });
for (const model of manifest.models) {
  if (!/^[A-Za-z0-9_.-]+\.onnx$/.test(model.file))
    throw new Error(`Unexpected model file name: ${model.file}`);
  const target = join(directory, model.file);
  const current = await existing(target);
  if (current && sha256(current) === model.sha256) {
    console.log(`face model ok: ${model.file}`);
    continue;
  }
  const response = await fetch(model.url, {
    redirect: 'follow',
    signal: AbortSignal.timeout(120_000),
  });
  if (!response.ok)
    throw new Error(
      `Download failed for ${model.file}: HTTP ${response.status}`,
    );
  const bytes = Buffer.from(await response.arrayBuffer());
  const actual = sha256(bytes);
  if (actual !== model.sha256)
    throw new Error(
      `SHA-256 mismatch for ${model.file}: expected ${model.sha256}, got ${actual}`,
    );
  const partial = `${target}.partial`;
  await writeFile(partial, bytes);
  await rm(target, { force: true });
  await rename(partial, target);
  console.log(`face model downloaded: ${model.file} (${bytes.length} bytes)`);
}

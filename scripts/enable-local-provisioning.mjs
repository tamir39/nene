import { readFileSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

// Explicit upgrade for an existing local foundation configuration. The secret
// is written only to the ignored backend .env, never to Flutter or stdout.
const root = fileURLToPath(new URL('../', import.meta.url));
try {
  const target = path.join(root, 'backend', '.env');
  const current = readFileSync(target, 'utf8');
  if (!/^SUPABASE_URL=http:\/\/127\.0\.0\.1:54321\r?$/m.test(current) ||
      /^NODE_ENV=production\r?$/m.test(current)) {
    throw new Error('Expected the existing local Nene backend configuration.');
  }
  const status = JSON.parse(execFileSync(process.execPath, [
    path.join(root, 'node_modules', 'supabase', 'dist', 'supabase.js'),
    'status', '--workdir', 'infrastructure', '--output', 'json',
  ], { cwd: root, encoding: 'utf8', timeout: 30_000, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] }));
  if (status.API_URL !== 'http://127.0.0.1:54321') throw new Error('Unexpected local stack.');
  const secret = status.SECRET_KEY || status.SERVICE_ROLE_KEY;
  if (typeof secret !== 'string' || !secret || /\s/.test(secret)) throw new Error('Invalid server key.');
  if (!secret.startsWith('sb_secret_')) {
    const payload = JSON.parse(Buffer.from(secret.split('.')[1] || '', 'base64url').toString('utf8'));
    if (payload.role !== 'service_role') throw new Error('Invalid server key.');
  }
  const lines = current.split(/\r?\n/).filter(line => !/^SUPABASE_SECRET_KEY=/.test(line));
  while (lines.at(-1) === '') lines.pop();
  writeFileSync(target, `${lines.join('\n')}\nSUPABASE_SECRET_KEY=${secret}\n`, { mode: 0o600 });
  console.log('Enabled local customer provisioning in ignored backend/.env. No keys printed; Flutter configuration unchanged.');
} catch {
  console.error('Local provisioning setup failed. Check the existing local backend configuration and start the Nene Supabase stack. No credentials were printed.');
  process.exitCode = 1;
}

import 'reflect-metadata';
import 'dotenv/config';
import { NestFactory } from '@nestjs/core';
import { AppModule } from '../app.module.js';
import { IdentityService } from './identity.service.js';

async function cleanup() {
  const app = await NestFactory.createApplicationContext(AppModule, {
    logger: false,
  });
  try {
    const result = await app.get(IdentityService).cleanup();
    console.log(
      `Removed ${result.removed} expired or abandoned private reference files (at most 100 per run).`,
    );
  } finally {
    await app.close();
  }
}
void cleanup().catch(() => {
  console.error(
    'Reference cleanup failed. No credentials or evidence details are logged.',
  );
  process.exitCode = 1;
});

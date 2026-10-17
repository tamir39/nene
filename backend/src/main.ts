import 'reflect-metadata';
import 'dotenv/config';
import { NestFactory } from '@nestjs/core';
import { AppModule } from './app.module.js';
import { ENVIRONMENT } from './config/config.module.js';
import type { Environment } from './config/environment.js';
import { configureApp } from './configure-app.js';

async function bootstrap(): Promise<void> {
  const app = await NestFactory.create(AppModule);
  const environment = app.get<Environment>(ENVIRONMENT);
  configureApp(app);
  await app.listen(environment.port, environment.host);
}

void bootstrap();

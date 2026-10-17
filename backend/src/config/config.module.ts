import { Global, Module } from '@nestjs/common';
import { readEnvironment, type Environment } from './environment.js';

export const ENVIRONMENT = Symbol('ENVIRONMENT');

@Global()
@Module({
  providers: [
    {
      provide: ENVIRONMENT,
      useFactory: (): Environment => readEnvironment(process.env),
    },
  ],
  exports: [ENVIRONMENT],
})
export class ConfigModule {}

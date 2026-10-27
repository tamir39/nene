import type { INestApplication } from '@nestjs/common';
import { json, type Request, type Response, type NextFunction } from 'express';

export function configureApp(app: INestApplication): void {
  // Only photo uploads need a larger JSON envelope. Other routes retain Nest's default limit.
  const photoParser = json({ limit: '14mb', inflate: false });
  // Nest detects a top-level middleware named jsonParser and would then omit
  // its default parser for every other route. Keep the route gate in a wrapper.
  app.use(function referencePhotoParser(
    req: Request,
    res: Response,
    next: NextFunction,
  ) {
    if (
      req.method === 'POST' &&
      /^\/api\/v1\/identity\/cases\/[0-9a-f-]+\/evidence\/?$/i.test(req.path)
    )
      photoParser(req, res, next);
    else next();
  });
  app.setGlobalPrefix('api/v1');
  app.enableShutdownHooks();
}

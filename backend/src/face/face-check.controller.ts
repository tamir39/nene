import {
  Body,
  Controller,
  ForbiddenException,
  Header,
  Headers,
  HttpCode,
  Injectable,
  Post,
  Req,
  UploadedFile,
  UseGuards,
  UseInterceptors,
  type CanActivate,
  type ExecutionContext,
} from '@nestjs/common';
import { FileInterceptor } from '@nestjs/platform-express';
import type { AuthenticatedRequest } from '../auth/auth.types.js';
import { uuid } from '../customers/customer.validation.js';
import { FaceCheckService } from './face-check.service.js';
import {
  faceCheckInput,
  faceUploadLimits,
  type UploadedSelfie,
} from './face-check.validation.js';

/** Rejects officers before the upload is parsed (guards run before interceptors). */
@Injectable()
export class CustomerOnlyGuard implements CanActivate {
  canActivate(context: ExecutionContext) {
    const req = context.switchToHttp().getRequest<AuthenticatedRequest>();
    if (req.user?.role !== 'customer')
      throw new ForbiddenException('A customer profile is required.');
    return true;
  }
}

@Controller('me/face-checks')
export class FaceCheckController {
  constructor(private readonly service: FaceCheckService) {}

  @Post()
  @HttpCode(200)
  @Header('Cache-Control', 'no-store')
  @UseGuards(CustomerOnlyGuard)
  @UseInterceptors(FileInterceptor('selfie', { limits: faceUploadLimits }))
  check(
    @Req() req: AuthenticatedRequest,
    @Headers('idempotency-key') key: unknown,
    @Body() body: unknown,
    @UploadedFile() file: UploadedSelfie | undefined,
  ) {
    return this.service.check(
      req,
      uuid(key, 'Idempotency-Key'),
      faceCheckInput(body, file),
    );
  }
}

import {
  BadRequestException,
  Body,
  Controller,
  ForbiddenException,
  Header,
  HttpCode,
  Post,
  Req,
} from '@nestjs/common';
import type { AuthenticatedRequest } from '../auth/auth.types.js';
import { answerActivityQuestion } from './activity-assistant.js';

export function assistantInput(body: unknown) {
  if (!body || typeof body !== 'object' || Array.isArray(body))
    throw new BadRequestException('Enter a question.');
  const input = body as Record<string, unknown>;
  if (
    Object.keys(input).some((k) => !['message', 'context'].includes(k)) ||
    typeof input.message !== 'string' ||
    !input.message.trim() ||
    input.message.length > 500 ||
    Array.from(input.message).some((character) => {
      const code = character.charCodeAt(0);
      return code === 127 || (code < 32 && ![9, 10, 13].includes(code));
    })
  )
    throw new BadRequestException('Enter a question of up to 500 characters.');
  if (
    input.context !== undefined &&
    input.context !== null &&
    input.context !== 'history_month'
  )
    throw new BadRequestException('Invalid conversation context.');
  return {
    message: input.message.trim(),
    context:
      input.context === 'history_month' ? ('history_month' as const) : null,
  };
}
@Controller('me/assistant')
export class AssistantController {
  @Post('messages')
  @HttpCode(200)
  @Header('Cache-Control', 'no-store')
  answer(@Req() request: AuthenticatedRequest, @Body() body: unknown) {
    if (request.user.role !== 'customer')
      throw new ForbiddenException('A customer profile is required.');
    const input = assistantInput(body);
    // This interpreter cannot query accounts, call providers or execute operations.
    return answerActivityQuestion(input.message, input.context);
  }
}

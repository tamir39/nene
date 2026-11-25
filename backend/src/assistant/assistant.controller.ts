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
import {
  answerActivityQuestion,
  isUnsupportedAnswer,
} from './activity-assistant.js';
import { AssistantModelService } from './assistant-model.service.js';

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
  constructor(private readonly model: AssistantModelService) {}

  @Post('messages')
  @HttpCode(200)
  @Header('Cache-Control', 'no-store')
  async answer(@Req() request: AuthenticatedRequest, @Body() body: unknown) {
    if (request.user.role !== 'customer')
      throw new ForbiddenException('A customer profile is required.');
    const input = assistantInput(body);
    const now = new Date();
    // Neither interpreter can query accounts or execute operations.
    const result = answerActivityQuestion(input.message, input.context, now);
    if (!isUnsupportedAnswer(result)) return result;
    // Optional AI fallback: only the message and current month leave the server,
    // and its output passes the same validation. Any failure keeps this reply.
    return (await this.model.interpret(input.message, now)) ?? result;
  }
}

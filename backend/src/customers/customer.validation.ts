import { BadRequestException } from '@nestjs/common';
import type {
  ContactInput,
  CreateCustomerInput,
  EditCustomerInput,
} from './customer.types.js';

const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function uuid(value: unknown, label = 'Customer ID'): string {
  if (typeof value !== 'string' || !uuidPattern.test(value)) {
    throw new BadRequestException(`${label} must be a UUID.`);
  }
  return value.toLowerCase();
}

function object(body: unknown, keys: string[]): Record<string, unknown> {
  if (!body || typeof body !== 'object' || Array.isArray(body)) {
    throw new BadRequestException('A JSON object is required.');
  }
  const value = body as Record<string, unknown>;
  if (
    Object.keys(value).some((key) => !keys.includes(key)) ||
    keys.some((key) => !Object.hasOwn(value, key))
  ) {
    throw new BadRequestException(
      'The request contains unsupported or missing fields.',
    );
  }
  return value;
}

function text(value: unknown, label: string, max: number): string {
  if (
    typeof value !== 'string' ||
    !value.trim() ||
    value.trim().length > max ||
    /\p{Cc}/u.test(value)
  ) {
    throw new BadRequestException(
      `${label} must contain 1 to ${max} characters without control characters.`,
    );
  }
  return value.trim();
}

function contact(value: Record<string, unknown>): ContactInput {
  let phone: string | null = null;
  if (value.phone !== null) {
    phone = text(value.phone, 'Phone', 32);
    if (!/^\+?[0-9 ()-]{5,32}$/.test(phone) || !/[0-9]/.test(phone))
      throw new BadRequestException('Phone must be a valid contact number.');
  }
  return {
    phone,
    address:
      value.address === null ? null : text(value.address, 'Address', 300),
  };
}

export function contactInput(body: unknown): ContactInput {
  return contact(object(body, ['phone', 'address']));
}

export function createInput(body: unknown): CreateCustomerInput {
  const value = object(body, [
    'email',
    'displayName',
    'phone',
    'address',
    'initialPassword',
  ]);
  const email = text(value.email, 'Email', 254).toLowerCase();
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email))
    throw new BadRequestException('Email must be valid.');
  if (
    typeof value.initialPassword !== 'string' ||
    value.initialPassword.length < 12 ||
    value.initialPassword.length > 128 ||
    /\p{Cc}/u.test(value.initialPassword)
  ) {
    throw new BadRequestException(
      'Initial password must contain 12 to 128 characters without control characters.',
    );
  }
  return {
    email,
    displayName: text(value.displayName, 'Display name', 120),
    ...contact(value),
    initialPassword: value.initialPassword,
  };
}

export function editInput(body: unknown): EditCustomerInput {
  const value = object(body, [
    'displayName',
    'phone',
    'address',
    'requestReason',
  ]);
  const requestReason = text(value.requestReason, 'Request reason', 500);
  if (requestReason.length < 5)
    throw new BadRequestException(
      'Request reason must contain 5 to 500 characters.',
    );
  return {
    displayName: text(value.displayName, 'Display name', 120),
    ...contact(value),
    requestReason,
  };
}

export function searchQuery(value: unknown): string {
  if (value === undefined || value === '') return '';
  if (
    typeof value !== 'string' ||
    value.length > 100 ||
    /\p{Cc}/u.test(value)
  ) {
    throw new BadRequestException(
      'Search must contain at most 100 characters.',
    );
  }
  return value.trim();
}

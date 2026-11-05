export type Activity = 'history' | 'transfer' | 'deposit' | 'withdrawal';
export type AssistantAction =
  { type: 'history'; month: string } | { type: Exclude<Activity, 'history'> };
export interface AssistantAnswer {
  reply: string;
  actions: AssistantAction[];
  context: 'history_month' | null;
}
function answer(
  reply: string,
  actions: AssistantAction[] = [],
  context: 'history_month' | null = null,
): AssistantAnswer {
  return { reply, actions, context };
}
function normalize(message: string) {
  return message
    .toLowerCase()
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .replace(/đ/g, 'd')
    .replace(/\s+/g, ' ')
    .trim();
}
const monthNames = [
  'january',
  'february',
  'march',
  'april',
  'may',
  'june',
  'july',
  'august',
  'september',
  'october',
  'november',
  'december',
];
const help =
  'I can help you open monthly transaction history, transfers, deposits or withdrawals. Try “show transactions for October 2026” or “lich su giao dich thang 10 nam 2026”. Ask one activity at a time. Bill payments and phone top-ups are not available yet.';

export function requestedMonth(text: string, now: Date): string | null {
  const values: string[] = [];
  const names = monthNames
    .flatMap((name) => [name, name.slice(0, 3)])
    .join('|');
  // Do not reduce “October and November 2026” to only the qualified month.
  if (
    new RegExp(
      `\\b(?:${names})(?: \\d{4})? (?:and|to|through|-) (?:${names})\\b`,
    ).test(text) ||
    /\bthang \d{1,2} (?:va|den|-) \d{1,2}\b/.test(text)
  )
    return null;
  const add = (year: number, month: number) => {
    values.push(
      year >= 2000 && year <= 2100 && month >= 1 && month <= 12
        ? `${year}-${String(month).padStart(2, '0')}`
        : 'invalid',
    );
  };
  // Full dates/ranges need clarification; never silently discard a day or second month.
  if (/\b\d{4}-\d{1,2}-\d{1,2}\b|\b\d{1,2}\/\d{1,2}\/\d{4}\b/.test(text))
    return null;
  for (const match of text.matchAll(/\b(\d{4})-(\d{1,2})\b/g))
    add(Number(match[1]), Number(match[2]));
  for (const match of text.matchAll(/\b(\d{1,2})\/(\d{4})\b/g))
    add(Number(match[2]), Number(match[1]));
  for (const match of text.matchAll(/\bthang (\d{1,2})(?: nam)? (\d{4})\b/g))
    add(Number(match[2]), Number(match[1]));
  for (let i = 0; i < monthNames.length; i++) {
    const name = monthNames[i]!;
    const pattern = new RegExp(
      `\\b(?:${name}|${name.slice(0, 3)})\\.? (\\d{4})\\b`,
      'g',
    );
    for (const match of text.matchAll(pattern)) add(Number(match[1]), i + 1);
  }
  const local = new Date(now.getTime() + 7 * 60 * 60 * 1000);
  if (/\b(this month|current month|thang nay)\b/.test(text))
    add(local.getUTCFullYear(), local.getUTCMonth() + 1);
  if (/\b(last month|previous month|thang truoc)\b/.test(text)) {
    const previous = new Date(
      Date.UTC(local.getUTCFullYear(), local.getUTCMonth() - 1, 1),
    );
    add(previous.getUTCFullYear(), previous.getUTCMonth() + 1);
  }
  return values.length === 1 && values[0] !== 'invalid' ? values[0]! : null;
}

/** Bounded, rule-based natural-language routing. Not a generative model or financial agent. */
export function answerActivityQuestion(
  message: string,
  context: 'history_month' | null = null,
  now = new Date(),
): AssistantAnswer {
  const text = normalize(message);
  if (
    /\b(password|mat khau|otp|authenticator code|recovery code|backup code|ma xac thuc)\b/.test(
      text,
    )
  )
    return answer(
      'Keep passwords, authenticator codes and recovery codes out of chat. Enter them only in the dedicated sign-in or security screen. Financial activities still require their normal review and authenticator confirmation.',
    );
  if (/https?:\/\/|www\.|\b\d{9,}\b/.test(text))
    return answer(
      'Please describe the activity without links, account numbers or personal details. Enter payment details only in the normal transaction screen. No transaction has been created.',
    );
  if (
    /\b(history|transactions|balance|lich su|so du)\b/.test(text) &&
    /\b(someone else|another customer|other customers|all customers|nguoi khac|khach hang khac)\b/.test(
      text,
    )
  )
    return answer(
      'You can only open your own accounts and transaction history. I cannot show another customer’s records.',
    );
  const history = /\b(history|transactions|statement|lich su|sao ke)\b/.test(
    text,
  );
  const phone = /\b(phone|mobile|top[ -]?up|dien thoai|nap the)\b/.test(text);
  const bills =
    /\b(electricity|water|tien dien(?! thoai)|tien nuoc)\b/.test(text) ||
    (!phone && /\b(bill|bills|hoa don)\b/.test(text));
  // “Deposit history” describes history; separate requests still need clarification.
  const historyOnly = history && !/\b(and|then|also|va|roi)\b/.test(text);
  const transfer =
    !historyOnly &&
    /\b(transfer|transfers|send money|chuyen tien|chuyen khoan)\b/.test(text);
  const deposit =
    !historyOnly &&
    !phone &&
    /\b(deposit|deposits|add money|nap tien)\b/.test(text);
  const withdrawal =
    !historyOnly && /\b(withdraw|withdrawal|withdrawals|rut tien)\b/.test(text);
  const count = [history, phone, bills, transfer, deposit, withdrawal].filter(
    Boolean,
  ).length;
  if (count > 1)
    return answer(
      'Please ask for one activity at a time: transaction history, transfer, deposit, withdrawal, bills or phone top-up.',
    );
  if (phone)
    return answer(
      'Phone top-ups are not implemented yet. I cannot charge or top up a phone account. Once that flow is available, this assistant will link to its normal review and confirmation screen.',
    );
  if (bills)
    return answer(
      'Electricity and water bill payments are not implemented yet. I cannot pay a bill or report one as paid. Their activity links will become available with the payment flows.',
    );
  const month = requestedMonth(text, now);
  const monthFollowUp =
    context === 'history_month' &&
    count === 0 &&
    /\b(month|thang|\d{4}|january|february|march|april|may|june|july|august|september|october|november|december|jan|feb|mar|apr|jun|jul|aug|sep|oct|nov|dec)\b/.test(
      text,
    );
  if (history || monthFollowUp) {
    if (!month)
      return answer(
        'Which single month would you like? Use YYYY-MM, a month and year (for example October 2026), “this month” or “last month”. Supported years are 2000–2100.',
        [],
        'history_month',
      );
    return answer(
      `Open your transaction history for ${month}, then choose one of your accounts. Only posted transactions for that month will be shown. Month boundaries use UTC+07.`,
      [{ type: 'history', month }],
    );
  }
  const activity = transfer
    ? 'transfer'
    : deposit
      ? 'deposit'
      : withdrawal
        ? 'withdrawal'
        : null;
  if (activity) {
    const label =
      activity === 'transfer'
        ? 'same-bank demo transfer'
        : activity === 'deposit'
          ? 'simulated cash deposit'
          : 'simulated cash withdrawal';
    if (
      activity === 'transfer' &&
      /\b(other bank|another bank|different bank|interbank|ngan hang khac|lien ngan hang)\b/.test(
        text,
      )
    )
      return answer(
        'Transfers to another bank are not implemented yet. The existing transfer flow supports only local synthetic accounts within Nene.',
      );
    return answer(
      `I can open the ${label} screen. Choose an eligible account and enter the details there. Existing funding, identity, amount limits and authenticator confirmation still apply. I have not created or sent a transaction.`,
      [{ type: activity }],
    );
  }
  return answer(help);
}

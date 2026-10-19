'use strict';
// Isolated design study: no API, storage, authentication, or banking side effects.
const paths = {
  eye: '<path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12Z"/><circle cx="12" cy="12" r="3"/>',
  user: '<circle cx="12" cy="8" r="3.5"/><path d="M5 21v-2a7 7 0 0 1 14 0v2"/>',
  users: '<circle cx="9" cy="8" r="3"/><path d="M2 21v-2a7 7 0 0 1 14 0v2M16 5a3 3 0 0 1 0 6M18 14a5 5 0 0 1 4 5v2"/>',
  home: '<path d="m3 10 9-7 9 7v11h-7v-7h-4v7H3Z"/>',
  accounts: '<rect x="3" y="5" width="18" height="15" rx="3"/><path d="M3 9h18M15 14h3M7 2h10"/>',
  transfer: '<path d="M4 7h15l-4-4M20 17H5l4 4M19 7l-4 4M5 17l4-4"/>',
  bill: '<path d="M6 3h12v18l-3-2-3 2-3-2-3 2ZM9 8h6M9 12h6"/>',
  phone: '<rect x="6" y="2" width="12" height="20" rx="3"/><path d="M10 5h4M11 18h2"/>',
  arrow: '<path d="M5 12h14m-6-6 6 6-6 6"/>',
  down: '<path d="M12 3v14m-5-5 5 5 5-5M4 20h16"/>',
  pin: '<path d="M19 10c0 5-7 12-7 12S5 15 5 10a7 7 0 1 1 14 0Z"/><circle cx="12" cy="10" r="2.5"/>',
  services: '<rect x="3" y="3" width="7" height="7" rx="2"/><rect x="14" y="3" width="7" height="7" rx="2"/><rect x="3" y="14" width="7" height="7" rx="2"/><rect x="14" y="14" width="7" height="7" rx="2"/>',
  chat: '<path d="M21 11a8 8 0 0 1-8 8H7l-5 3 1-7a8 8 0 0 1-1-4 8 8 0 0 1 8-8h3a8 8 0 0 1 8 8Z"/><path d="M7 10h10M7 14h6"/>',
  plus: '<path d="M12 4v16M4 12h16"/>',
  search: '<circle cx="10" cy="10" r="6.5"/><path d="m15 15 6 6"/>',
  rates: '<path d="m5 19 14-14"/><circle cx="6.5" cy="6.5" r="3.5"/><circle cx="17.5" cy="17.5" r="3.5"/>',
};
document.querySelectorAll('[data-icon]').forEach(el => {
  el.innerHTML = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${paths[el.dataset.icon]}</svg>`;
});
const details = {
  C02: ['Accounts', 'See your checking, saving and mortgage accounts. Each has a distinct detail view; saving shows rate and monthly profit, mortgage shows the periodic amount due.', 'BR-05–BR-08 · PDF p. 2 §3'],
  C03: ['Checking account', 'View your balance and history. Deposit, withdraw or transfer through review and the required transaction verification flow.', 'BR-05, BR-08, BR-09 · PDF p. 2 §3–4'],
  C04: ['Saving account', 'View balance, rate and monetary profit per month. This home card is only a summary. The detail screen must explain the selected calculation and effective-date policy.', 'BR-05, BR-06 · PDF p. 2 §3'],
  C05: ['Mortgage account', 'View the payment amount due and due date for the selected monthly or two-week repayment convention. The amount shown is a layout fixture, not a calculated quote.', 'BR-05, BR-07 · PDF p. 2 §3'],
  C06: ['History and transaction detail', 'Filter your account transactions by month and open a receipt. Preserve the requested month when arriving from the Assistant.', 'BR-08, BR-14 · PDF p. 2 §3, §7'],
  C08: ['Transfer', 'Choose a same-bank or other-bank destination, enter details, review the amount and recipient, complete any required high-value identity check and transaction-bound 2FA, then view the confirmed result.', 'BR-03, BR-04, BR-09 · PDF p. 2 §2, §4'],
  C09: ['Services', 'Electricity, water, phone top-up, transfer and nearby branches. Flight tickets, movie tickets, hotels and e-commerce remain in the screen map until the lecturer confirms the purchase/booking breadth.', 'BR-09–BR-13 · PDF p. 2 §4–6'],
  C10: ['Pay bills', 'Choose electricity or water, look up the bill, review the funding account and amount, then complete required verification. Payment and bill fulfillment need distinct confirmed outcomes.', 'BR-04, BR-10, BR-11 · PDF p. 2 §2, §4–5'],
  C11: ['Phone top-up', 'Choose the phone account and amount, review and verify the operation, then show payment and top-up fulfillment results.', 'BR-04, BR-10, BR-11 · PDF p. 2 §2, §4–5'],
  C13: ['Nearby branches', 'Locate the customer, show all nearby offices in the declared coverage area and recommend the shortest walking route to the nearest office. Handle denied permission and unavailable routes.', 'BR-13 · PDF p. 2 §6'],
  C14: ['Assistant', 'Ask about phone services, bills or transactions for a particular month. Answers link to allowed app activities; they never bypass normal financial confirmation and verification.', 'BR-14 · PDF p. 2 §7'],
  C15: ['Customer profile', 'View and edit permitted personal information, open identity enrollment/status, or sign out. Customers cannot change roles, balances, rates or their own verification outcome.', 'BR-01–BR-03 · PDF p. 1 §1, p. 2 §2'],
  O02: ['Customers', 'Search authorized customer records and open a record to assist with identification, initial account provisioning or requested information changes.', 'BR-01–BR-03 · PDF p. 1 §1, p. 2 §2'],
  O04: ['Create customer', 'Capture permitted details, review, then create the customer identity, profile and initial banking account. Provide safe access instructions. Creating a record does not mean identity verification is complete or funds have been deposited.', 'BR-02, BR-03, BR-05 · PDF p. 1 §1, p. 2 §2–3'],
  O06: ['Assist with identification', 'Open the customer record and help complete the selected biometric/eKYC method. The method and high-value checks are still to be chosen; an uploaded image alone is not verification.', 'BR-03 · PDF p. 2 §2'],
  O07: ['Saving rates', 'Review the applicable rate, unit, scope and effective date. Edit and confirm changes under documented bank policy. This does not add a general policy engine.', 'BR-06 · PDF p. 2 §3'],
  O08: ['Officer profile', 'View the authenticated officer identity and sign out. Permissions are loaded by the backend, with no role picker.', 'BR-01, BR-03 · PDF p. 1 §1, p. 2 §2'],
};
const dialog = document.querySelector('#scope-dialog');
let dialogTrigger;
document.querySelectorAll('[data-detail]').forEach(button => button.addEventListener('click', () => {
  const [title, body, source] = details[button.dataset.detail];
  document.querySelector('#dialog-title').textContent = title;
  document.querySelector('#dialog-body').textContent = body;
  document.querySelector('#dialog-source').textContent = source;
  dialogTrigger = button;
  dialog.showModal();
}));
document.querySelector('#close-dialog').addEventListener('click', () => dialog.close());
dialog.addEventListener('close', () => dialogTrigger?.focus());
document.querySelector('#show-password').addEventListener('click', event => {
  const input = document.querySelector('#password');
  input.type = input.type === 'password' ? 'text' : 'password';
  event.currentTarget.setAttribute('aria-label', input.type === 'password' ? 'Show password' : 'Hide password');
});
document.querySelector('#sign-in-form').addEventListener('submit', event => {
  event.preventDefault();
  document.querySelector('#signin-message').textContent = 'Preview only. No credentials are sent or saved.';
});
let balanceVisible = true;
document.querySelector('#balance-toggle').addEventListener('click', event => {
  balanceVisible = !balanceVisible;
  document.querySelector('#checking-balance').innerHTML = balanceVisible ? '12,850,000 <span>₫</span>' : '••• <span>₫</span>';
  event.currentTarget.setAttribute('aria-label', balanceVisible ? 'Hide checking balance' : 'Show checking balance');
});
const states = {
  home: {
    loading: ['Loading your accounts', 'Your balances and recent activity will appear here.'],
    empty: ['No accounts yet', 'Your bank officer can help set up your first account.'],
    error: ['Accounts could not load', 'Check your connection, then try again. Your balance is unavailable.'],
  },
  officer: {
    loading: ['Loading customer records', 'Checking for incomplete identification records.'],
    empty: ['No identification to continue', 'Find an existing customer above or create a customer to begin.'],
    error: ['Customer records could not load', 'Check your connection, then try again.'],
  },
};
function setState(screen, state) {
  if (screen === 'signin') {
    const button = document.querySelector('#sign-in-button');
    button.disabled = state === 'loading';
    button.textContent = state === 'loading' ? 'Signing in…' : 'Sign in →';
    document.querySelector('#signin-message').textContent = state === 'error' ? 'Unable to sign in. Check your email and password, then try again.' : '';
    document.querySelector('#sign-in-form').setAttribute('aria-busy', String(state === 'loading'));
    return;
  }
  const content = document.querySelector(`[data-content="${screen}"]`);
  const panel = document.querySelector(`[data-state-panel="${screen}"]`);
  content.hidden = state !== 'default';
  panel.hidden = state === 'default';
  if (state === 'default') return;
  const [title, message] = states[screen][state];
  panel.innerHTML = `<div class="state-icon" aria-hidden="true">${state === 'error' ? '!' : state === 'loading' ? '…' : '—'}</div><h4>${title}</h4><p>${message}</p>${state === 'loading' ? '<div class="skeleton big" aria-hidden="true"></div><div class="skeleton" aria-hidden="true"></div>' : ''}${state === 'error' ? '<button class="primary">Try again</button>' : ''}`;
  panel.querySelector('button')?.addEventListener('click', () => {
    const select = document.querySelector(`select[data-screen="${screen}"]`);
    select.value = 'default';
    setState(screen, 'default');
    select.focus();
  });
}
document.querySelectorAll('select[data-screen]').forEach(select => select.addEventListener('change', () => setState(select.dataset.screen, select.value)));
document.querySelectorAll('[data-reset]').forEach(button => button.addEventListener('click', () => {
  document.querySelector(`select[data-screen="${button.dataset.reset}"]`).value = 'default';
  setState(button.dataset.reset, 'default');
}));
document.querySelector('#customer-search').addEventListener('input', event => {
  const query = event.target.value.trim().toLowerCase();
  let matches = 0;
  document.querySelectorAll('[data-name]').forEach(row => {
    row.hidden = !row.dataset.name.includes(query);
    if (!row.hidden) matches++;
  });
  document.querySelector('#search-message').textContent = query ? (matches ? `${matches} matching demo ${matches === 1 ? 'customer' : 'customers'}.` : 'No matching demo customers. Clear the search to see both examples.') : '';
});

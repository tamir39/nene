// Branded page shown after VNPay sends the customer back. It is a fixed
// document: no request values are ever interpolated, and the strict CSP set
// by the controller blocks scripts, external loads, forms and framing.

const logo = `<svg class="logo" viewBox="0 0 320 320" aria-hidden="true">
<path fill="#4C929E" d="M8 92Q8 68 34 61L239 7Q278-3 278 39L278 78L155 118Q55 86 8 92Z"/>
<path fill="#F6C9A5" d="M168 125L282 86Q306 78 306 102L306 145Q236 143 168 125Z"/>
<path fill="#4C929E" d="M4 120Q4 102 25 107C98 115 173 156 302 159Q320 159 320 181L320 267Q320 320 269 320L55 320Q4 320 4 269Z"/>
</svg>`;

const checkIcon = `<svg viewBox="0 0 24 24" aria-hidden="true"><path fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" d="M5 12.5l4.5 4.5L19 7.5"/></svg>`;
const infoIcon = `<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="9" fill="none" stroke="currentColor" stroke-width="2"/><path fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" d="M12 11v5.5M12 7.6v.1"/></svg>`;

const styles = `
*{box-sizing:border-box}
body{margin:0;min-height:100vh;background:#F8F7F2;color:#172F38;font-family:"Be Vietnam Pro",-apple-system,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif;padding:0 16px 32px;overflow-wrap:break-word}
header{max-width:440px;margin:0 auto;display:flex;align-items:center;gap:10px;padding:28px 4px 20px}
.logo{width:34px;height:34px}
.word{font-size:30px;font-weight:700;letter-spacing:-1px;color:#4C929E}
main{max-width:440px;margin:0 auto;background:#fff;border:1px solid #E6ECEB;border-radius:24px;padding:32px 24px 26px;text-align:center}
.badge{width:72px;height:72px;margin:0 auto 18px;border-radius:50%;display:grid;place-items:center}
.badge svg{width:38px;height:38px}
.ok{background:#E3F3EA;color:#1F7A4D}
.neutral{background:#EFF7F5;color:#286E78}
h1{margin:0 0 10px;font-size:24px;line-height:1.25;letter-spacing:-.3px}
p{margin:0;color:#4D626B;line-height:1.55;font-size:15.5px}
ol{text-align:left;margin:24px 0 0;padding:0;list-style:none;counter-reset:step}
li{counter-increment:step;display:flex;gap:12px;align-items:flex-start;padding:12px 0;border-top:1px solid #E6ECEB;font-size:15px;line-height:1.45}
li span{flex:1;min-width:0}
li::before{content:counter(step);flex:0 0 28px;height:28px;border-radius:50%;background:#286E78;color:#fff;font-weight:700;font-size:14px;display:grid;place-items:center}
.note{margin-top:18px;padding:14px 16px;border-radius:16px;background:#FCEDE1;color:#1C525B;font-size:13.5px;text-align:left;line-height:1.5}
footer{margin:18px auto 0;color:#4D626B;font-size:12.5px;text-align:center;max-width:440px;line-height:1.5}`;

function page(title: string, lead: string, badge: 'ok' | 'neutral'): string {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>Nene · Payment</title>
<style>${styles}</style>
</head>
<body>
<header>${logo}<span class="word">nene</span></header>
<main>
<div class="badge ${badge}">${badge === 'ok' ? checkIcon : infoIcon}</div>
<h1>${title}</h1>
<p>${lead}</p>
<ol>
<li><span>Return to the Nene app or tab.</span></li>
<li><span>Open <strong>Bills &amp; payments</strong> and check the payment status. Sign in again if your session has ended.</span></li>
</ol>
<div class="note">Nene records a result only after verifying VNPay’s signature. This page never confirms a payment on its own.</div>
</main>
<footer>Educational banking project · VNPay sandbox only. No real bill, phone credit, movie ticket, seat reservation or admission is fulfilled.</footer>
</body>
</html>`;
}

/** Shown when VNPay's signed result was verified and recorded (or already was). */
export const RETURN_PAGE_RECEIVED = page(
  'Payment result received',
  'VNPay sent a signed result and Nene has recorded it.',
  'ok',
);

/** Shown for every other visit: no query, tampered or unverifiable values. */
export const RETURN_PAGE_DEFAULT = page(
  'Return to Nene',
  'Check your payment status in the Nene app.',
  'neutral',
);

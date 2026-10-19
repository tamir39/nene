# Nene UI direction study

Status: proposed for user review, 2026-10-19. Open pocket and the teal/apricot palette are confirmed; this layout, typography and screen styling are proposals. No Flutter screens or launcher assets changed. All sample identities, references, dates, amounts and rates are synthetic layout fixtures, not financial calculation results or integration evidence.

[Open the interactive study](ui/index.html) · [Complete screen map](SCREEN_MAP.md) · [Brand reference](BRANDING.md)

![Sign-in, customer home and officer workspace proposals](ui/overview.png)

The HTML is a self-contained, local design artifact, not a new web banking product. Open `docs/ui/index.html` in a browser. It loads only local CSS, JavaScript and an SVG. It has no API access, analytics, remote fonts or persistence; its content security policy disables connections and form submission. Do not enter real credentials. Screen actions open planning notes, not implemented financial flows.

## Three representative screens

| Screen | Direction and scope | Review artifact |
| --- | --- | --- |
| Shared sign-in | Large Open pocket mark, short welcome, persistent email/password labels, one primary sign-in action and officer-provisioning guidance. Role comes from authenticated server data; no role picker or self-signup. BR-01/BR-03. | [Sign-in](ui/signin.png) |
| Customer home | Checking balance first, common actions next, separate saving/mortgage summaries, recent history and a branch shortcut below. Five destinations: Home, Accounts, Services, Assistant, Profile. No asset/debt aggregation or financial analytics. BR-05–BR-09/BR-11/BR-13. | [Customer home](ui/home.png) |
| Officer workspace | Create customer as the main action; find a customer, continue incomplete identification, access savings-rate management. Four destinations: Workspace, Customers, Rates, Profile. One mobile app, with a distinct officer interface. BR-01–BR-03/BR-06. | [Officer workspace](ui/officer.png) |

Phone frames are approximately 390 × 844 CSS pixels on the desktop board. Content scrolls within them; bottom navigation stays reachable. Some secondary content is intentionally below the first viewport. Small displays stack the three studies vertically. The customer account summary is not the complete account-detail layout: saving details must show monthly monetary profit, and mortgage details must show the chosen repayment convention and due amount.

## Visual decisions proposed

- **Surfaces:** warm ivory page, white form/account surfaces, deep teal primary controls and checking summary. Use open spacing and modest rounding, not a card around every paragraph.
- **Apricot:** retain the logo insert and small emphasis details. Do not use apricot text on ivory or rely on an apricot outline to identify an essential control. Officer/customer avatar tints are decorative.
- **Typography:** use a familiar system sans for the study, with 23–25px screen titles, 32px balance, 16px inputs, 14–16px main copy and 12px secondary copy. Compact navigation labels are 11px. Browser rendering uses Segoe UI/Arial; propose platform-aware Flutter typography and validate Android text scaling during implementation. No font package is added. The plain `nene` text beside the mark is a study lockup, not approved production wordmark lettering.
- **Numbers and language:** use tabular numerals; separate amounts by account type; write status in words. English and VND are preview assumptions, not a new multilingual or currency requirement. Display formatting/calculation policy remains unresolved.
- **Controls:** consistent outline icons, labeled actions, visible keyboard focus, neutral secondary actions, teal primary actions. Proposed Flutter touch targets should be at least 48 logical pixels. Final platform accessibility must be verified in the implementation.
- **Tone:** short, calm instructions. Missing data is not zero; uncertain financial outcomes are not success. Errors explain a next action without exposing provider or database internals.

The code-authored [study SVG](ui/open-pocket-study.svg) follows the selected main B reference: upright body, rising rear fold, curved opening and apricot insert. It is used to keep the mockups consistent. It is not a finalized production master, launcher asset, approved wordmark, or a new trademark assessment. Production geometry, clear space, small-size and launcher-mask checks remain on the roadmap.

## Preview interactions

- Each screen's **Preview state** selector exposes default/loading/error; customer and officer also expose empty states. They are manual fixtures and do not call services.
- Sign-in provides a password visibility toggle. Submitting displays a preview-only message and does not authenticate or transmit/store input.
- Customer home can hide/show the checking amount. Account, service, history, branch and assistant actions open requirement-linked notes.
- Officer search filters the two synthetic customer examples. Real search permissions, queries and provisioning are not implemented.
- Planning-note dialogs support Escape and restore focus to the initiating control. The state “Try again” action returns to the default fixture; it does not imply server recovery.

## Verification record

Checked on 2026-10-19 using a temporary headless Microsoft Edge browser and local files:

- Reviewed all three original PDF pages visually and extracted their text; mapped all BR-01–BR-14 to destinations/journeys in [SCREEN_MAP.md](SCREEN_MAP.md). No original assessment file was modified.
- Rendered and visually inspected the three default screens, error/empty examples and narrow layout. Loading states and all selector changes were exercised. No page JavaScript errors or external requests occurred.
- At 1440, 768, 390 and 320px viewport widths, neither the page nor phone content areas had horizontal overflow. At 390px, a 200% text-size stress check had no horizontal overflow in the scrollable content regions, but crowded/clipped the fixed bottom-navigation labels. An adaptive large-text navigation treatment is required before app implementation; this study does not pass a full 200% accessibility review.
- Exercised search match/no-match/reset, hide/show balance, password visibility, loading submit disablement, screen-map dialog opening, Escape closure and focus restoration. All buttons had visible text or accessible labels.
- Checked exact solid-color pairs with WCAG relative-luminance calculations: white/teal **9.11:1**, teal/ivory **8.50:1**, primary ink/ivory **13.05:1**, secondary ink/ivory **5.98:1**, secondary ink/soft surface **5.56:1**, teal/avatar tint **7.00:1**, apricot/teal **5.34:1**, error text/ivory **6.67:1**. These text pairs exceed 4.5:1. Input border/white is **3.99:1**, above the 3:1 component target. This does not establish contrast for every future state or imply apricot/ivory is usable text.
- Reviewed Markdown links and Git diff before publishing. No application tests were needed for this isolated design/documentation change; no application behavior changed.

Still to verify: user preference, all remaining screen layouts, production logo and font treatment, full screen-reader traversal, platform semantics, large-text navigation and touch targets on Android, keyboard occlusion, and final implemented financial/security behavior. Banking/provider choices and lecturer interpretations remain in [SCREEN_MAP.md](SCREEN_MAP.md) and [SCOPE.md](../SCOPE.md).

## Next implementation boundary

Review this visual direction, then detail the first officer-to-customer journey: officer creation of a synthetic customer plus initial account, customer sign-in, own profile/account display and permitted profile edits. Keep identity status truthful; do not enable financial posting before the required identity and transaction-2FA mechanisms are implemented. Keep all later PDF features in the roadmap.

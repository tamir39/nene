# Nene privacy policy

**Nene – Student Banking Demo** (Android package `vn.nene.bank`)
Last updated: 26 November 2026

Nene is an **educational demo** built for a Mobile Apps Development course at Ton Duc Thang University. It is **not a real bank**. All accounts, balances and transactions are synthetic, and payments use the **VNPay sandbox** (test environment), so no real money moves. Please use only made-up test details in the app.

## Who runs the app

The student project team that published Nene on Google Play. For questions or requests, open an issue at <https://github.com/tamir39/nene/issues> or use the developer email shown on the Google Play listing.

## What the app collects and why

| Data | When | Why |
| --- | --- | --- |
| Email address and password | A bank officer creates your sign-in | To sign you in. Passwords are handled by our authentication provider and are never visible to the team. |
| Name, phone number and address | Entered by a bank officer or by you | To show and edit your demo bank profile |
| Reference face photo | Only if you choose to upload one in **Identity reference** | So a bank officer can review it before money features unlock in the demo, and so large transfers can be compared with it (next row). |
| Selfie for a large transfer | Only for a transfer over 10,000,000 VND, or one that takes the day's transfers over 20,000,000 VND | A selfie taken for a large transfer is compared with your reference photo on our server and then discarded. Nene keeps only the result (match or no match), the similarity and anti-spoof scores, the time and which transfer review it belongs to, plus whether your phone reported a blink and a head turn. Nene never stores the selfie or any face template. This check is a demo safeguard, not certified biometrics or electronic identity verification (eKYC). |
| Authenticator setup | Only if you set up transaction security | To confirm each transaction with a 6-digit code. Codes are checked when entered and are not stored. |
| Demo accounts, transactions and payment records | When you use banking features | To show balances, history and payment status. All amounts are synthetic. |
| Approximate or precise location | Only when you open **Offices** and allow location | To find the nearest (fictional) Nene office and a walking route. Location is **not stored** or logged. |
| Assistant messages | Only when you use **Assistant** | To suggest the right in-app task. Messages are **not stored** by Nene. To reuse an AI answer for the same question, the server keeps only a one-way fingerprint of the question in memory for up to 6 hours, never the text. If the optional AI helper is turned on, a message the built-in rules cannot understand is sent to Google's Gemini API to interpret it (see below). |

Nene has **no advertising, no analytics and no tracking**, and never sells or shares personal data for marketing.

## Service providers

| Provider | Role | Data it receives |
| --- | --- | --- |
| Supabase (Singapore region) | Database, sign-in and private file storage | Profile, demo banking data, authenticator setup, reference photos |
| Render (Singapore region) | Runs the Nene server, including the face comparison for large transfers | All app requests while they are processed, including a large-transfer selfie, which is held in memory only for the comparison |
| VNPay sandbox | Test payment page for demo bills, top-ups and tickets | Order number and amount. Card details are entered on VNPay's page, never in Nene. |
| FOSSGIS Valhalla routing service | Walking routes on the Offices map | The start point and the selected office's location |
| OpenStreetMap tile servers | Map images on the Offices map | Your device's IP address and the map area being viewed |
| Google (Gemini API) | Only when the optional AI helper is turned on: interprets assistant messages the built-in rules cannot understand | The text of that one message and the current month, sent by the Nene server. No account numbers, balances, profile, history or sign-in details. Messages that contain six or more digits in a row or an email address are not sent. On Gemini's free tier, Google may use the message and the reply to provide, improve and develop its products, and human reviewers may read them after Google disconnects them from Nene's account and key ([Gemini API terms](https://aistudio.google.com/docs/terms)). Do not type personal details into the assistant. |

## Security and retention

- Data is sent over encrypted HTTPS connections. Banking data is only reachable through the Nene server, which checks who you are and what you may access.
- Reference photos are private: only you and bank officers can view them. The server also reads your reference photo, in memory, when you confirm a large transfer with a selfie. Access to a photo expires 60 days after its upload step starts; expired files can then be deleted.
- Sign-in sessions are kept in memory only and end when the app is closed.
- Because this is a course demo, the database may be reset or deleted after the course ends.

## Your choices

- Uploading a photo, setting up an authenticator, sharing location and using the assistant are all optional. A selfie is asked for only when you confirm a large transfer; smaller transfers do not need one.
- You can ask for your demo data to be deleted through the contact options above.
- Nene is intended for users aged 18 and older and is not directed at anyone under 18.

## Changes

Updates to this policy are published at this page with a new "Last updated" date.

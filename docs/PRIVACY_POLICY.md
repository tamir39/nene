# Nene privacy policy

**Nene – Student Banking Demo** (Android package `vn.nene.bank`)
Last updated: 25 November 2026

Nene is an **educational demo** built for a Mobile Apps Development course at Ton Duc Thang University. It is **not a real bank**. All accounts, balances and transactions are synthetic, and payments use the **VNPay sandbox** (test environment), so no real money moves. Please use only made-up test details in the app.

## Who runs the app

The student project team that published Nene on Google Play. For questions or requests, open an issue at <https://github.com/tamir39/nene/issues> or use the developer email shown on the Google Play listing.

## What the app collects and why

| Data | When | Why |
| --- | --- | --- |
| Email address and password | A bank officer creates your sign-in | To sign you in. Passwords are handled by our authentication provider and are never visible to the team. |
| Name, phone number and address | Entered by a bank officer or by you | To show and edit your demo bank profile |
| Reference face photo | Only if you choose to upload one in **Identity reference** | So a bank officer can review it before money features unlock in the demo. Nene does **not** analyse, match or recognise faces on its servers. |
| Authenticator setup | Only if you set up transaction security | To confirm each transaction with a 6-digit code. Codes are checked when entered and are not stored. |
| Demo accounts, transactions and payment records | When you use banking features | To show balances, history and payment status. All amounts are synthetic. |
| Approximate or precise location | Only when you open **Offices** and allow location | To find the nearest (fictional) Nene office and a walking route. Location is **not stored** or logged. |
| Assistant messages | Only when you use **Assistant** | To suggest the right in-app task. Messages are **not stored** and are not sent to any AI provider. |

Nene has **no advertising, no analytics and no tracking**, and never sells or shares personal data for marketing.

## Service providers

| Provider | Role | Data it receives |
| --- | --- | --- |
| Supabase (Singapore region) | Database, sign-in and private file storage | Profile, demo banking data, authenticator setup, reference photos |
| Render (Singapore region) | Runs the Nene server | All app requests while they are processed |
| VNPay sandbox | Test payment page for demo bills, top-ups and tickets | Order number and amount. Card details are entered on VNPay's page, never in Nene. |
| FOSSGIS Valhalla routing service | Walking routes on the Offices map | The start point and the selected office's location |
| OpenStreetMap tile servers | Map images on the Offices map | Your device's IP address and the map area being viewed |

## Security and retention

- Data is sent over encrypted HTTPS connections. Banking data is only reachable through the Nene server, which checks who you are and what you may access.
- Reference photos are private: only you and bank officers can view them. Access to a photo expires 60 days after its upload step starts; expired files can then be deleted.
- Sign-in sessions are kept in memory only and end when the app is closed.
- Because this is a course demo, the database may be reset or deleted after the course ends.

## Your choices

- Uploading a photo, setting up an authenticator, sharing location and using the assistant are all optional.
- You can ask for your demo data to be deleted through the contact options above.
- Nene is not directed at children under 13.

## Changes

Updates to this policy are published at this page with a new "Last updated" date.

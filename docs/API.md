# Base API contract

Status: base implementation, 2026-10-15. This contract supports BR-01/BR-03 and TR-03/TR-06; it does not complete those requirements.

Base path: `/api/v1`. The Flutter client obtains its session from Supabase Auth and sends `Authorization: Bearer <access-token>` to NestJS. Banking data is never queried through the mobile Supabase database client.

| Endpoint | Access | Response |
| --- | --- | --- |
| `GET /health` | Public | Liveness only: `status`, `service`, `check`. Does not claim the database or identity service is healthy. |
| `GET /me` | Supabase session plus active server-owned profile | `id`, `email`, `displayName`, and `role` (`customer` or `officer`). |

NestJS validates the token through Supabase Auth, then reads the matching `bank.user_profiles` row through the restricted database login. Supabase user metadata and client-supplied role values cannot grant officer access. Routes require authentication by default; only explicitly public routes bypass the guard.

Expected failures: `401` for absent/invalid authentication, `403` for a missing or disabled application profile, and `503` for unavailable dependencies. The app presents useful messages without rendering provider errors, SQL, or tokens.

There are no balance updates, transfers, payments, officer provisioning, identity verification, or transaction-2FA endpoints yet. Add these only with their BR requirement, backend authorization, validation, and relevant tests. No endpoint may allow a client to set its own financial balance, officer role, or identity-verification result.

See [the source requirements](../REQUIREMENTS.md), [the scope boundaries](../SCOPE.md), and [the architecture](../DESIGN.md).

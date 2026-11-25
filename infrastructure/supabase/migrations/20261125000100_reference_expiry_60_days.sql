-- BR-03 support: the reference access lifetime is a coursework policy, not a PDF rule.
-- Seven days let accepted demo references lapse before the course could review the
-- hosted app, so new drafts now last 60 days. Existing rows keep their expiry; this
-- migration changes no data.
alter table bank.identity_cases alter column expires_at set default now() + interval '60 days';
comment on table bank.identity_cases is
  'One current reference case per customer. Version protects commands; revision binds a photo to the reviewed name. Sixty-day expiry is a local coursework policy, not a PDF rule.';

-- BR-13/TR-03: fictional Nene locations, not real bank offices or TDTU facilities.
begin;
create table bank.branches (
  id text primary key,
  name text not null,
  area text not null,
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  is_demo boolean not null default true check (is_demo)
);
insert into bank.branches (id, name, area, latitude, longitude) values
  ('nene-tdtu-demo', 'Nene TDTU · demo', 'Nguyen Huu Tho area', 10.7340, 106.7000),
  ('nene-tan-phong-demo', 'Nene Tan Phong · demo', 'Tan Phong area', 10.7290, 106.7030),
  ('nene-north-demo', 'Nene North · demo', 'North of TDTU', 10.7410, 106.7010);
alter table bank.branches enable row level security;
alter table bank.branches force row level security;
revoke all on bank.branches from public, anon, authenticated, service_role;
grant select on bank.branches to nene_api;
create policy branches_api_read on bank.branches for select to nene_api using (true);
commit;

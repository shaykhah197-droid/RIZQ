-- Password Store: allow public customers to submit maintenance requests,
-- while keeping request records readable/manageable only by store admins.

alter table public.service_requests enable row level security;

grant insert on table public.service_requests to anon, authenticated;
grant select, update on table public.service_requests to authenticated;

drop policy if exists password_service_requests_public_insert on public.service_requests;
create policy password_service_requests_public_insert
on public.service_requests
for insert
to anon, authenticated
with check (
  length(trim(customer_name)) between 2 and 100
  and length(trim(customer_phone)) between 5 and 25
  and length(trim(address)) between 2 and 300
  and length(trim(problem_description)) between 3 and 2000
  and length(trim(service_type)) between 2 and 100
  and status = 'new'
);

drop policy if exists password_service_requests_admin_read on public.service_requests;
create policy password_service_requests_admin_read
on public.service_requests
for select
to authenticated
using (public.password_store_is_admin());

drop policy if exists password_service_requests_admin_update on public.service_requests;
create policy password_service_requests_admin_update
on public.service_requests
for update
to authenticated
using (public.password_store_is_admin())
with check (public.password_store_is_admin());

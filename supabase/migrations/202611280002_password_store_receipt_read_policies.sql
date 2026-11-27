-- Password Store: allow receipt previews for the owning customer and store admins.
-- Keep the bucket private; signed URLs still require these SELECT policies.

create or replace function public.password_store_is_admin()
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select
    lower(coalesce(auth.jwt() ->> 'email', '')) = 'elbtawy.mahmoud@gmail.com'
    or exists (
      select 1
      from public.store_admins a
      where lower(a.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
        and a.role in ('full', 'limited')
    );
$$;

revoke all on function public.password_store_is_admin() from public;
grant execute on function public.password_store_is_admin() to authenticated;

drop policy if exists password_receipts_customer_read on storage.objects;
create policy password_receipts_customer_read
on storage.objects
for select
to authenticated
using (
  bucket_id = 'payment-receipts'
  and (storage.foldername(name))[1] = auth.uid()::text
);

drop policy if exists password_receipts_admin_read on storage.objects;
create policy password_receipts_admin_read
on storage.objects
for select
to authenticated
using (
  bucket_id = 'payment-receipts'
  and public.password_store_is_admin()
);

grant select on storage.objects to authenticated;

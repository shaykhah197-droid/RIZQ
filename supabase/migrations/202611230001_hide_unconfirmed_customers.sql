-- Return only email-confirmed customers to authenticated administrators.
-- The function runs with the database owner's privileges so it can safely
-- inspect auth.users without exposing that table to the browser client.
create or replace function public.admin_list_confirmed_customers()
returns table (
  id uuid,
  full_name text,
  referral_code text,
  created_at timestamptz,
  balance numeric
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if coalesce((auth.jwt() -> 'app_metadata' ->> 'role') = 'admin', false) is not true then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  return query
  select
    p.id,
    p.full_name::text,
    p.referral_code::text,
    p.created_at,
    coalesce(w.balance, 0)::numeric
  from public.profiles as p
  join auth.users as u on u.id = p.id
  left join public.wallets as w on w.user_id = p.id
  where u.email_confirmed_at is not null
  order by p.created_at desc
  limit 200;
end;
$$;

revoke all on function public.admin_list_confirmed_customers() from public;
grant execute on function public.admin_list_confirmed_customers() to authenticated;

-- RIZQ admin customer profiles, searchable customer codes, and internal support notes.
-- All RPCs explicitly require the authenticated admin app_metadata role.
-- This migration is additive: it does not change balances, packages, tasks, or payment records.

create table if not exists public.admin_customer_notes (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references auth.users(id) on delete cascade,
  admin_id uuid not null references auth.users(id) on delete restrict,
  note text not null check (length(trim(note)) between 1 and 2000),
  created_at timestamptz not null default now()
);

create index if not exists admin_customer_notes_customer_created_idx
  on public.admin_customer_notes(customer_id, created_at desc);

alter table public.admin_customer_notes enable row level security;
revoke all on public.admin_customer_notes from anon, authenticated;
grant select, insert on public.admin_customer_notes to authenticated;

drop policy if exists admin_customer_notes_admin_select on public.admin_customer_notes;
create policy admin_customer_notes_admin_select
  on public.admin_customer_notes
  for select to authenticated
  using ((auth.jwt() -> 'app_metadata' ->> 'role') = 'admin');

drop policy if exists admin_customer_notes_admin_insert on public.admin_customer_notes;
create policy admin_customer_notes_admin_insert
  on public.admin_customer_notes
  for insert to authenticated
  with check (
    admin_id = auth.uid()
    and (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin'
  );

create or replace function public.admin_search_customer(p_query text)
returns table (
  id uuid,
  customer_code text,
  full_name text,
  email text,
  referral_code text,
  created_at timestamptz,
  balance numeric
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  q text := lower(trim(coalesce(p_query, '')));
begin
  if coalesce((auth.jwt() -> 'app_metadata' ->> 'role') = 'admin', false) is not true then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if length(q) < 2 then
    return;
  end if;

  return query
  select
    p.id,
    ('RZQ-' || upper(substr(replace(p.id::text, '-', ''), 1, 12)))::text as customer_code,
    coalesce(p.full_name, '')::text,
    coalesce(u.email, '')::text,
    coalesce(p.referral_code, '')::text,
    p.created_at,
    coalesce(w.balance, 0)::numeric
  from public.profiles p
  join auth.users u on u.id = p.id
  left join public.wallets w on w.user_id = p.id
  where u.email_confirmed_at is not null
    and (
      lower(coalesce(p.full_name, '')) like '%' || q || '%'
      or lower(coalesce(u.email, '')) like '%' || q || '%'
      or lower(coalesce(p.referral_code, '')) like '%' || q || '%'
      or lower(p.id::text) = q
      or lower('RZQ-' || substr(replace(p.id::text, '-', ''), 1, 12)) like '%' || q || '%'
    )
  order by p.created_at desc
  limit 50;
end;
$$;

revoke all on function public.admin_search_customer(text) from public;
grant execute on function public.admin_search_customer(text) to authenticated;

create or replace function public.admin_get_customer_details(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  result jsonb;
begin
  if coalesce((auth.jwt() -> 'app_metadata' ->> 'role') = 'admin', false) is not true then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if not exists (
    select 1
    from public.profiles p
    join auth.users u on u.id = p.id
    where p.id = p_user_id
      and u.email_confirmed_at is not null
  ) then
    raise exception 'customer not found' using errcode = 'P0002';
  end if;

  select jsonb_build_object(
    'profile', (
      select jsonb_build_object(
        'id', p.id,
        'customer_code', 'RZQ-' || upper(substr(replace(p.id::text, '-', ''), 1, 12)),
        'full_name', p.full_name,
        'email', u.email,
        'referral_code', p.referral_code,
        'created_at', p.created_at
      )
      from public.profiles p
      join auth.users u on u.id = p.id
      where p.id = p_user_id
    ),
    'wallet', coalesce((
      select to_jsonb(w) from public.wallets w where w.user_id = p_user_id
    ), '{}'::jsonb),
    'packages', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'user_package_id', up.id,
          'package_id', up.package_id,
          'name', pk.name,
          'price', pk.price
        )
        order by pk.price
      )
      from public.user_packages up
      left join public.packages pk on pk.id = up.package_id
      where up.user_id = p_user_id
    ), '[]'::jsonb),
    'deposits', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.created_at desc)
      from (
        select d.id, d.amount, d.status, d.method_id, d.transaction_reference,
               d.proof_note, d.created_at
        from public.deposit_requests d
        where d.user_id = p_user_id
        order by d.created_at desc
        limit 30
      ) x
    ), '[]'::jsonb),
    'withdrawals', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.created_at desc)
      from (
        select w.id, w.amount, w.status, w.method, w.transaction_reference,
               w.created_at
        from public.withdrawal_requests w
        where w.user_id = p_user_id
        order by w.created_at desc
        limit 30
      ) x
    ), '[]'::jsonb),
    'transactions', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.created_at desc)
      from (
        select t.id, t.transaction_type, t.amount, t.description, t.created_at
        from public.wallet_transactions t
        where t.user_id = p_user_id
        order by t.created_at desc
        limit 50
      ) x
    ), '[]'::jsonb),
    'support_conversations', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.updated_at desc)
      from (
        select c.id, c.status, c.created_at, c.updated_at
        from public.support_conversations c
        where c.user_id = p_user_id
        order by c.updated_at desc
        limit 20
      ) x
    ), '[]'::jsonb),
    'support_messages', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.created_at desc)
      from (
        select m.id, m.conversation_id, m.sender_role, m.body,
               m.attachment_paths, m.created_at
        from public.support_messages m
        join public.support_conversations c on c.id = m.conversation_id
        where c.user_id = p_user_id
        order by m.created_at desc
        limit 100
      ) x
    ), '[]'::jsonb),
    'notes', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', n.id,
          'note', n.note,
          'admin_id', n.admin_id,
          'created_at', n.created_at
        )
        order by n.created_at desc
      )
      from public.admin_customer_notes n
      where n.customer_id = p_user_id
    ), '[]'::jsonb)
  ) into result;

  return result;
end;
$$;

revoke all on function public.admin_get_customer_details(uuid) from public;
grant execute on function public.admin_get_customer_details(uuid) to authenticated;

create or replace function public.admin_add_customer_note(p_user_id uuid, p_note text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  new_note_id uuid;
begin
  if coalesce((auth.jwt() -> 'app_metadata' ->> 'role') = 'admin', false) is not true then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  if length(trim(coalesce(p_note, ''))) not between 1 and 2000 then
    raise exception 'note must be between 1 and 2000 characters';
  end if;

  if not exists (
    select 1 from public.profiles p
    join auth.users u on u.id = p.id
    where p.id = p_user_id and u.email_confirmed_at is not null
  ) then
    raise exception 'customer not found' using errcode = 'P0002';
  end if;

  insert into public.admin_customer_notes(customer_id, admin_id, note)
  values (p_user_id, auth.uid(), trim(p_note))
  returning id into new_note_id;

  return new_note_id;
end;
$$;

revoke all on function public.admin_add_customer_note(uuid, text) from public;
grant execute on function public.admin_add_customer_note(uuid, text) to authenticated;

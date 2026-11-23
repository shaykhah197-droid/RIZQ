create table if not exists public.rizq_push_subscriptions (
  endpoint text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  subscription jsonb not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.rizq_push_subscriptions enable row level security;
revoke all on public.rizq_push_subscriptions from anon, authenticated;

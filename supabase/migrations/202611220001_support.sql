-- RIZQ customer support tables and policies
create table if not exists public.support_conversations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  status text not null default 'open' check (status in ('open','replied','closed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists public.support_messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.support_conversations(id) on delete cascade,
  sender_id uuid not null references auth.users(id) on delete cascade,
  sender_role text not null check (sender_role in ('customer','admin')),
  body text not null default '',
  attachment_paths text[] not null default '{}',
  created_at timestamptz not null default now(),
  constraint support_message_has_content check (length(trim(body)) > 0 or cardinality(attachment_paths) > 0)
);
create index if not exists support_conversations_user_updated_idx on public.support_conversations(user_id, updated_at desc);
create index if not exists support_messages_conversation_created_idx on public.support_messages(conversation_id, created_at);
alter table public.support_conversations enable row level security;
alter table public.support_messages enable row level security;
drop policy if exists support_conversations_customer_select on public.support_conversations;
create policy support_conversations_customer_select on public.support_conversations for select to authenticated using (user_id = auth.uid());
drop policy if exists support_conversations_admin_select on public.support_conversations;
create policy support_conversations_admin_select on public.support_conversations for select to authenticated using ((auth.jwt()->'app_metadata'->>'role') = 'admin');
drop policy if exists support_conversations_customer_insert on public.support_conversations;
create policy support_conversations_customer_insert on public.support_conversations for insert to authenticated with check (user_id = auth.uid());
drop policy if exists support_conversations_admin_update on public.support_conversations;
create policy support_conversations_admin_update on public.support_conversations for update to authenticated using ((auth.jwt()->'app_metadata'->>'role') = 'admin') with check ((auth.jwt()->'app_metadata'->>'role') = 'admin');
drop policy if exists support_messages_customer_select on public.support_messages;
create policy support_messages_customer_select on public.support_messages for select to authenticated using (exists(select 1 from public.support_conversations c where c.id=conversation_id and c.user_id=auth.uid()));
drop policy if exists support_messages_admin_select on public.support_messages;
create policy support_messages_admin_select on public.support_messages for select to authenticated using ((auth.jwt()->'app_metadata'->>'role') = 'admin');
drop policy if exists support_messages_customer_insert on public.support_messages;
create policy support_messages_customer_insert on public.support_messages for insert to authenticated with check (sender_id=auth.uid() and sender_role='customer' and exists(select 1 from public.support_conversations c where c.id=conversation_id and c.user_id=auth.uid()));
drop policy if exists support_messages_admin_insert on public.support_messages;
create policy support_messages_admin_insert on public.support_messages for insert to authenticated with check (sender_id=auth.uid() and sender_role='admin' and (auth.jwt()->'app_metadata'->>'role')='admin');
drop policy if exists support_attachments_admin_read on storage.objects;
create policy support_attachments_admin_read on storage.objects for select to authenticated using (bucket_id='support-attachments' and (auth.jwt()->'app_metadata'->>'role')='admin');
create or replace function public.rizq_support_touch_conversation()
returns trigger language plpgsql security definer set search_path=public as $$
begin
 update public.support_conversations
 set updated_at=now(),
     status=case when new.sender_role='customer' then 'open' else 'replied' end
 where id=new.conversation_id;
 return new;
end; $$;
drop trigger if exists rizq_support_message_touch on public.support_messages;
create trigger rizq_support_message_touch after insert on public.support_messages
for each row execute function public.rizq_support_touch_conversation();

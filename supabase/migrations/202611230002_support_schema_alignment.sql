-- Align legacy support_messages columns with the secure RIZQ support schema.
-- Safe to run more than once. Keeps legacy columns nullable for old deployments.
alter table public.support_messages
  add column if not exists sender_id uuid references auth.users(id) on delete cascade,
  add column if not exists sender_role text,
  add column if not exists body text,
  add column if not exists attachment_paths text[];

alter table public.support_messages
  alter column sender_id set default auth.uid(),
  alter column body set default '',
  alter column body set not null,
  alter column attachment_paths set default '{}',
  alter column attachment_paths set not null;

do $$
begin
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='support_messages' and column_name='sender') then
    execute $q$update public.support_messages set sender_role=case when sender='admin' then 'admin' else 'customer' end where sender_role is null$q$;
    execute 'alter table public.support_messages alter column sender drop not null';
  end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='support_messages' and column_name='message') then
    execute $q$update public.support_messages set body=coalesce(message,'') where body is null or body=''$q$;
    execute 'alter table public.support_messages alter column message drop not null';
  end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='support_messages' and column_name='image_path') then
    execute $q$update public.support_messages set attachment_paths=array[image_path] where image_path is not null and cardinality(attachment_paths)=0$q$;
    execute 'alter table public.support_messages alter column image_path drop not null';
  end if;
end $$;

update public.support_messages
set body=coalesce(body,''), attachment_paths=coalesce(attachment_paths,'{}'), sender_role=coalesce(sender_role,'customer')
where sender_role is null;
alter table public.support_messages
  alter column sender_role set default 'customer',
  alter column sender_role set not null;

alter table public.support_messages enable row level security;
drop policy if exists support_messages_customer_select on public.support_messages;
create policy support_messages_customer_select on public.support_messages
for select to authenticated
using (exists(select 1 from public.support_conversations c where c.id=conversation_id and c.user_id=auth.uid()));
drop policy if exists support_messages_admin_select on public.support_messages;
create policy support_messages_admin_select on public.support_messages
for select to authenticated
using ((auth.jwt()->'app_metadata'->>'role')='admin');
drop policy if exists support_messages_customer_insert on public.support_messages;
create policy support_messages_customer_insert on public.support_messages
for insert to authenticated
with check (
  sender_id=auth.uid()
  and sender_role='customer'
  and exists(select 1 from public.support_conversations c where c.id=conversation_id and c.user_id=auth.uid())
);
drop policy if exists support_messages_admin_insert on public.support_messages;
create policy support_messages_admin_insert on public.support_messages
for insert to authenticated
with check (
  sender_id=auth.uid()
  and sender_role='admin'
  and (auth.jwt()->'app_metadata'->>'role')='admin'
);

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

grant select, insert on public.support_messages to authenticated;

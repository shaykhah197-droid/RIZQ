-- RIZQ support schema alignment for the legacy table:
-- id, conversation_id, sender, message, "Image", created_at.
-- Preserves existing rows and does not require sender_id for historical admin messages.

alter table public.support_messages
  add column if not exists sender_id uuid references auth.users(id) on delete set null,
  add column if not exists sender_role text,
  add column if not exists body text,
  add column if not exists attachment_paths text[];

alter table public.support_messages
  alter column body set default '',
  alter column attachment_paths set default '{}';

do $$
declare
  image_column text;
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='support_messages' and column_name='sender'
  ) then
    execute $q$
      update public.support_messages
      set sender_role = case
        when lower(trim(coalesce(sender,''))) in ('admin','administrator','الإدارة','مدير المنصة') then 'admin'
        else 'customer'
      end
      where sender_role is null
    $q$;
    execute 'alter table public.support_messages alter column sender drop not null';
  end if;

  if exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='support_messages' and column_name='message'
  ) then
    execute $q$
      update public.support_messages
      set body = coalesce(nullif(body,''), nullif(message,''))
      where body is null or body=''
    $q$;
    execute 'alter table public.support_messages alter column message drop not null';
  end if;

  select column_name into image_column
  from information_schema.columns
  where table_schema='public' and table_name='support_messages'
    and lower(column_name)='image'
  limit 1;

  if image_column is not null then
    execute format(
      'update public.support_messages
       set attachment_paths = array[%I]
       where %I is not null
         and coalesce(cardinality(attachment_paths),0)=0',
      image_column, image_column
    );
    execute format('alter table public.support_messages alter column %I drop not null', image_column);
  end if;
end $$;

update public.support_messages m
set sender_id = c.user_id
from public.support_conversations c
where c.id = m.conversation_id
  and m.sender_id is null
  and coalesce(m.sender_role,'customer') = 'customer';

update public.support_messages
set body = coalesce(nullif(body,''), '[رسالة سابقة]'),
    attachment_paths = coalesce(attachment_paths,'{}'),
    sender_role = coalesce(sender_role,'customer')
where body is null or body='' or attachment_paths is null or sender_role is null;

alter table public.support_messages
  alter column body set not null,
  alter column attachment_paths set not null,
  alter column sender_role set default 'customer',
  alter column sender_role set not null;

alter table public.support_messages enable row level security;

drop policy if exists support_messages_customer_select on public.support_messages;
create policy support_messages_customer_select on public.support_messages
for select to authenticated
using (
  exists (
    select 1 from public.support_conversations c
    where c.id = conversation_id and c.user_id = auth.uid()
  )
);

drop policy if exists support_messages_admin_select on public.support_messages;
create policy support_messages_admin_select on public.support_messages
for select to authenticated
using ((auth.jwt()->'app_metadata'->>'role')='admin');

drop policy if exists support_messages_customer_insert on public.support_messages;
create policy support_messages_customer_insert on public.support_messages
for insert to authenticated
with check (
  sender_id = auth.uid()
  and sender_role = 'customer'
  and exists (
    select 1 from public.support_conversations c
    where c.id = conversation_id and c.user_id = auth.uid()
  )
);

drop policy if exists support_messages_admin_insert on public.support_messages;
create policy support_messages_admin_insert on public.support_messages
for insert to authenticated
with check (
  sender_id = auth.uid()
  and sender_role = 'admin'
  and (auth.jwt()->'app_metadata'->>'role')='admin'
);

create or replace function public.rizq_support_touch_conversation()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.support_conversations
  set updated_at = now(),
      status = case when new.sender_role='customer' then 'open' else 'replied' end
  where id = new.conversation_id;
  return new;
end;
$$;

drop trigger if exists rizq_support_message_touch on public.support_messages;
create trigger rizq_support_message_touch
after insert on public.support_messages
for each row execute function public.rizq_support_touch_conversation();

grant select, insert on public.support_messages to authenticated;

-- Replace legacy content checks that still validate the old message/Image columns.
alter table public.support_messages
  drop constraint if exists support_message_content,
  drop constraint if exists support_message_has_content;

alter table public.support_messages
  add constraint support_message_content
  check (length(trim(coalesce(body,''))) > 0
         or coalesce(cardinality(attachment_paths),0) > 0);

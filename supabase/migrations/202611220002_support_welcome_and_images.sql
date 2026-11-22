-- Allow customers to view images attached to their own support conversation,
-- including images uploaded by an administrator.
drop policy if exists support_attachments_customer_conversation_read on storage.objects;
create policy support_attachments_customer_conversation_read
on storage.objects for select to authenticated
using (
  bucket_id = 'support-attachments'
  and exists (
    select 1
    from public.support_messages m
    join public.support_conversations c on c.id = m.conversation_id
    where auth.uid() = c.user_id
      and name = any(m.attachment_paths)
  )
);

-- Add one automatic welcome message when a support conversation is first opened.
create or replace function public.rizq_support_welcome_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.support_messages
    (conversation_id, sender_id, sender_role, body, attachment_paths)
  values
    (new.id, new.user_id, 'admin',
     'أهلاً بك في خدمة عملاء رزق. اكتب استفسارك وسيرد عليك فريق الدعم في أقرب وقت.',
     '{}');
  return new;
end;
$$;

drop trigger if exists rizq_support_conversation_welcome on public.support_conversations;
create trigger rizq_support_conversation_welcome
after insert on public.support_conversations
for each row execute function public.rizq_support_welcome_message();

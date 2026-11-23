-- Align the legacy support message content check with the current schema.
alter table public.support_messages
  drop constraint if exists support_message_content,
  drop constraint if exists support_message_has_content;

alter table public.support_messages
  add constraint support_message_content
  check (
    length(trim(coalesce(body, ''))) > 0
    or coalesce(cardinality(attachment_paths), 0) > 0
  );

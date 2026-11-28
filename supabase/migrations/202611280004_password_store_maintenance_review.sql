-- Password Store: store a visible reason when a maintenance request is rejected.
alter table public.service_requests
  add column if not exists rejection_reason text;

comment on column public.service_requests.rejection_reason is
  'Reason entered by the store admin when rejecting a maintenance request.';

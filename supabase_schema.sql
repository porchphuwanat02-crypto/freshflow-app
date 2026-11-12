create table if not exists public.freshflow_user_state (
  user_id uuid primary key references auth.users (id) on delete cascade,
  state jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

alter table public.freshflow_user_state enable row level security;

drop policy if exists "Users can manage their own FreshFlow state"
  on public.freshflow_user_state;

create policy "Users can manage their own FreshFlow state"
  on public.freshflow_user_state
  for all
  to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

revoke all on public.freshflow_user_state from anon;
grant select, insert, update on public.freshflow_user_state to authenticated;

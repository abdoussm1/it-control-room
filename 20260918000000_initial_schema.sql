create extension if not exists pgcrypto;

create type public.app_role as enum ('administrateur', 'technicien');
create type public.pc_state as enum ('functional', 'issue', 'down', 'offline');
create type public.problem_status as enum ('pending', 'active', 'resolved');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  role public.app_role not null default 'technicien',
  created_at timestamptz not null default now()
);

create table public.rooms (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  location text not null,
  created_at timestamptz not null default now()
);

create table public.pcs (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete restrict,
  name text not null,
  state public.pc_state not null default 'functional',
  created_at timestamptz not null default now(),
  unique (room_id, name)
);

create table public.technical_problems (
  id uuid primary key default gen_random_uuid(),
  pc_id uuid not null references public.pcs(id) on delete cascade,
  category text not null check (category in ('Réseau', 'Matériel', 'Logiciel', 'Autre')),
  problem_type text not null,
  description text not null,
  priority text not null default 'Moyenne' check (priority in ('Faible', 'Moyenne', 'Élevée')),
  status public.problem_status not null default 'pending',
  assigned_to uuid references public.profiles(id) on delete set null,
  created_by uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);

create table public.interventions (
  id uuid primary key default gen_random_uuid(),
  problem_id uuid not null references public.technical_problems(id) on delete cascade,
  technician_id uuid not null references public.profiles(id) on delete restrict,
  description text not null,
  created_at timestamptz not null default now()
);

create table public.history (
  id uuid primary key default gen_random_uuid(),
  problem_id uuid references public.technical_problems(id) on delete set null,
  actor_id uuid references public.profiles(id) on delete set null,
  event_type text not null,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index technical_problems_assigned_to_idx on public.technical_problems(assigned_to);
create index technical_problems_pc_id_idx on public.technical_problems(pc_id);
create index interventions_problem_id_idx on public.interventions(problem_id);
create index history_problem_id_idx on public.history(problem_id);

create or replace function public.current_user_role()
returns public.app_role
language sql stable security definer set search_path = public
as $$ select role from public.profiles where id = auth.uid() $$;

create or replace function public.is_admin()
returns boolean
language sql stable security definer set search_path = public
as $$ select public.current_user_role() = 'administrateur'::public.app_role $$;

create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, role)
  values (new.id, coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)), 'technicien')
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
after insert on auth.users
for each row execute procedure public.handle_new_user();

create or replace function public.log_problem_change()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    insert into public.history(problem_id, actor_id, event_type, details) values (new.id, auth.uid(), 'created', jsonb_build_object('status', new.status));
  elsif old.status is distinct from new.status or old.assigned_to is distinct from new.assigned_to then
    insert into public.history(problem_id, actor_id, event_type, details) values (new.id, auth.uid(), 'updated', jsonb_build_object('old_status', old.status, 'new_status', new.status, 'assigned_to', new.assigned_to));
  end if;
  return new;
end;
$$;

create trigger technical_problem_history
after insert or update on public.technical_problems
for each row execute procedure public.log_problem_change();

alter table public.profiles enable row level security;
alter table public.rooms enable row level security;
alter table public.pcs enable row level security;
alter table public.technical_problems enable row level security;
alter table public.interventions enable row level security;
alter table public.history enable row level security;

create policy profiles_read_authenticated on public.profiles for select to authenticated using (true);
create policy profiles_admin_write on public.profiles for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy rooms_read_authenticated on public.rooms for select to authenticated using (true);
create policy rooms_admin_write on public.rooms for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy pcs_read_authenticated on public.pcs for select to authenticated using (true);
create policy pcs_admin_write on public.pcs for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy problems_read_authenticated on public.technical_problems for select to authenticated using (public.is_admin() or assigned_to = auth.uid() or created_by = auth.uid());
create policy problems_admin_insert on public.technical_problems for insert to authenticated with check (public.is_admin() and created_by = auth.uid());
create policy problems_admin_update on public.technical_problems for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy problems_technician_update on public.technical_problems for update to authenticated using (assigned_to = auth.uid()) with check (assigned_to = auth.uid());
create policy interventions_read_authenticated on public.interventions for select to authenticated using (public.is_admin() or technician_id = auth.uid());
create policy interventions_insert_assigned on public.interventions for insert to authenticated with check (technician_id = auth.uid() and exists (select 1 from public.technical_problems p where p.id = problem_id and (p.assigned_to = auth.uid() or public.is_admin())));
create policy history_read_authenticated on public.history for select to authenticated using (public.is_admin() or actor_id = auth.uid() or exists (select 1 from public.technical_problems p where p.id = problem_id and p.assigned_to = auth.uid()));

insert into public.rooms (name, location)
values
  ('Salle 1', 'Bâtiment A · Étage 1'), ('Salle 2', 'Bâtiment A · Étage 1'), ('Salle 3', 'Bâtiment A · Étage 1'),
  ('Salle 4', 'Bâtiment A · Étage 2'), ('Salle 5', 'Bâtiment A · Étage 2'), ('Salle 6', 'Bâtiment A · Étage 2'),
  ('Administration', 'Bâtiment administratif')
on conflict (name) do nothing;

insert into public.pcs (room_id, name, state)
select r.id, case when r.name = 'Administration' then 'PC Admin ' || lpad(n::text, 2, '0') else 'PC ' || lpad(n::text, 2, '0') end, 'functional'
from public.rooms r cross join generate_series(1, 10) n
where r.name <> 'Administration'
on conflict (room_id, name) do nothing;

insert into public.pcs (room_id, name, state)
select r.id, 'PC Admin ' || lpad(n::text, 2, '0'), 'functional'
from public.rooms r cross join generate_series(1, 3) n
where r.name = 'Administration'
on conflict (room_id, name) do nothing;

-- Batería CVU: libro del admin. Cada CVU es independiente.
-- El acceso lo decide public.admins. El navegador no escribe saldos directo.

create table if not exists public.admins (
  user_id uuid primary key references auth.users (id) on delete cascade,
  email text not null unique,
  created_at timestamptz not null default now()
);

create table if not exists public.cvu_accounts (
  id integer primary key check (id between 1 and 1000),
  group_name text not null check (group_name in ('receiver', 'payer')),
  cvu char(22) not null unique,
  balance bigint not null check (balance >= 0 and balance <= 500000)
);

create table if not exists public.payment_orders (
  id bigint generated always as identity primary key,
  amount bigint not null check (amount > 0),
  fees bigint not null check (fees >= 0),
  destination char(22) not null,
  beneficiary text not null,
  dest_type text not null check (dest_type in ('CVU', 'CBU')),
  status text not null,
  created_at timestamptz not null default now()
);

create table if not exists public.order_parts (
  id bigint generated always as identity primary key,
  order_id bigint not null references public.payment_orders (id) on delete cascade,
  account_id integer not null references public.cvu_accounts (id),
  amount bigint not null check (amount > 0),
  fee bigint not null check (fee >= 0),
  status text not null
);

create table if not exists public.controller_events (
  id bigint generated always as identity primary key,
  account_id integer not null references public.cvu_accounts (id),
  direction text not null,
  amount bigint not null check (amount >= 0),
  status text not null,
  reference text,
  created_at timestamptz not null default now()
);

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.admins where user_id = auth.uid()
  );
$$;

create or replace function public.grant_admin()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if lower(new.email) = 'matchsystem@proton.me' then
    insert into public.admins (user_id, email)
    values (new.id, lower(new.email))
    on conflict (user_id) do update set email = excluded.email;
  end if;
  return new;
end;
$$;

drop trigger if exists grant_admin_on_signup on auth.users;
create trigger grant_admin_on_signup
  after insert on auth.users
  for each row execute function public.grant_admin();

create or replace function public.seed_balances()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.cvu_accounts (id, group_name, cvu, balance)
  select
    i,
    case when i <= 700 then 'receiver' else 'payer' end,
    '00001234' || lpad((10000000000000 + i - 1)::text, 14, '0'),
    case
      when (i - 1) % 19 = 0 then 0
      else greatest(12000, ((i - 1) * 7919 + 13427) % 500001)
    end
  from generate_series(1, 1000) as i
  on conflict (id) do update
    set group_name = excluded.group_name,
        cvu = excluded.cvu,
        balance = excluded.balance;
end;
$$;

select public.seed_balances();

create or replace function public.reset_battery()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'acceso denegado';
  end if;
  delete from public.controller_events;
  delete from public.order_parts;
  delete from public.payment_orders;
  perform public.seed_balances();
end;
$$;

create or replace function public.record_incoming()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_account public.cvu_accounts%rowtype;
  v_amount bigint;
begin
  if not public.is_admin() then
    raise exception 'acceso denegado';
  end if;
  select * into v_account
  from public.cvu_accounts
  where group_name = 'receiver' and balance <= 350000
  order by id
  for update
  limit 1;
  if not found then
    raise exception 'no hay receptora con capacidad';
  end if;
  v_amount := least(75000, 500000 - v_account.balance);
  update public.cvu_accounts set balance = balance + v_amount where id = v_account.id;
  insert into public.controller_events (account_id, direction, amount, status)
  values (v_account.id, 'Ingreso externo', v_amount, 'Acreditado');
  return jsonb_build_object('account_id', v_account.id, 'amount', v_amount);
end;
$$;

create or replace function public.fund_payer(p_fee bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_from public.cvu_accounts%rowtype;
  v_to public.cvu_accounts%rowtype;
  v_amount bigint := 75000;
  v_ref text;
begin
  if not public.is_admin() then
    raise exception 'acceso denegado';
  end if;
  if p_fee is null or p_fee < 0 then
    raise exception 'costo invalido';
  end if;
  select * into v_from
  from public.cvu_accounts
  where group_name = 'receiver' and balance >= v_amount + p_fee
  order by random()
  for update
  limit 1;
  select * into v_to
  from public.cvu_accounts
  where group_name = 'payer' and balance <= 500000 - v_amount
  order by random()
  for update
  limit 1;
  if v_from.id is null or v_to.id is null then
    raise exception 'no hay cuentas para este fondeo';
  end if;
  v_ref := 'F' || lpad(nextval('public.controller_events_id_seq')::text, 6, '0');
  update public.cvu_accounts set balance = balance - (v_amount + p_fee) where id = v_from.id;
  update public.cvu_accounts set balance = balance + v_amount where id = v_to.id;
  insert into public.controller_events (account_id, direction, amount, status, reference)
  values
    (v_from.id, 'Fondeo enviado', v_amount + p_fee, 'Acreditado', v_ref),
    (v_to.id, 'Fondeo recibido', v_amount, 'Acreditado', v_ref);
  return jsonb_build_object(
    'reference', v_ref,
    'from_id', v_from.id,
    'to_id', v_to.id,
    'amount', v_amount,
    'fee', p_fee
  );
end;
$$;

create or replace function public.apply_payment(
  p_destination text,
  p_beneficiary text,
  p_type text,
  p_fee bigint,
  p_parts jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_total bigint := 0;
  v_count integer := 0;
  v_part jsonb;
  v_amount bigint;
  v_account public.cvu_accounts%rowtype;
  v_order_id bigint;
begin
  if not public.is_admin() then
    raise exception 'acceso denegado';
  end if;
  if p_destination !~ '^[0-9]{22}$' then
    raise exception 'destino invalido';
  end if;
  if p_type not in ('CVU', 'CBU') then
    raise exception 'tipo invalido';
  end if;
  if p_beneficiary is null or length(btrim(p_beneficiary)) = 0 or length(p_beneficiary) > 70 then
    raise exception 'beneficiario invalido';
  end if;
  if p_fee is null or p_fee < 0 then
    raise exception 'costo invalido';
  end if;
  if jsonb_typeof(p_parts) <> 'array' or jsonb_array_length(p_parts) = 0 then
    raise exception 'reparto vacio';
  end if;

  for v_part in select value from jsonb_array_elements(p_parts)
  loop
    v_amount := (v_part->>'amount')::bigint;
    if v_amount is null or v_amount <= 0 then
      raise exception 'tramo invalido';
    end if;
    v_total := v_total + v_amount;
    v_count := v_count + 1;
  end loop;

  if v_total < 100000 and v_count <> 1 then
    raise exception 'un pago menor a 100000 sale de una sola pagadora';
  end if;

  for v_part in select value from jsonb_array_elements(p_parts)
  loop
    v_amount := (v_part->>'amount')::bigint;
    select * into v_account
    from public.cvu_accounts
    where id = (v_part->>'id')::integer
    for update;
    if not found or v_account.group_name <> 'payer' then
      raise exception 'pagadora invalida';
    end if;
    if v_account.balance < v_amount + p_fee then
      raise exception 'saldo insuficiente';
    end if;
    if v_total < 100000 and v_account.balance <= 200000 then
      raise exception 'la pagadora debe superar 200000';
    end if;
    if v_total >= 100000 and v_amount % 1000 = 0 then
      raise exception 'el tramo no puede ser multiplo cerrado de 1000';
    end if;
  end loop;

  insert into public.payment_orders (amount, fees, destination, beneficiary, dest_type, status)
  values (v_total, v_count * p_fee, p_destination, btrim(p_beneficiary), p_type, 'Acreditada')
  returning id into v_order_id;

  for v_part in select value from jsonb_array_elements(p_parts)
  loop
    v_amount := (v_part->>'amount')::bigint;
    update public.cvu_accounts
      set balance = balance - (v_amount + p_fee)
      where id = (v_part->>'id')::integer;
    insert into public.order_parts (order_id, account_id, amount, fee, status)
    values (v_order_id, (v_part->>'id')::integer, v_amount, p_fee, 'Acreditada');
    insert into public.controller_events (account_id, direction, amount, status, reference)
    values ((v_part->>'id')::integer, 'Egreso', v_amount + p_fee, 'Acreditado', 'O' || v_order_id);
  end loop;

  return jsonb_build_object('order_id', v_order_id, 'status', 'Acreditada', 'amount', v_total);
end;
$$;

alter table public.admins enable row level security;
alter table public.cvu_accounts enable row level security;
alter table public.payment_orders enable row level security;
alter table public.order_parts enable row level security;
alter table public.controller_events enable row level security;

drop policy if exists admins_self on public.admins;
create policy admins_self on public.admins
  for select to authenticated
  using (user_id = auth.uid());

drop policy if exists accounts_admin_read on public.cvu_accounts;
create policy accounts_admin_read on public.cvu_accounts
  for select to authenticated
  using (public.is_admin());

drop policy if exists orders_admin_read on public.payment_orders;
create policy orders_admin_read on public.payment_orders
  for select to authenticated
  using (public.is_admin());

drop policy if exists parts_admin_read on public.order_parts;
create policy parts_admin_read on public.order_parts
  for select to authenticated
  using (public.is_admin());

drop policy if exists events_admin_read on public.controller_events;
create policy events_admin_read on public.controller_events
  for select to authenticated
  using (public.is_admin());

revoke all on public.admins, public.cvu_accounts, public.payment_orders, public.order_parts, public.controller_events from anon, public;
grant select on public.admins, public.cvu_accounts, public.payment_orders, public.order_parts, public.controller_events to authenticated;

revoke all on function public.is_admin() from public, anon;
revoke all on function public.seed_balances() from public, anon, authenticated;
revoke all on function public.reset_battery() from public, anon;
revoke all on function public.record_incoming() from public, anon;
revoke all on function public.fund_payer(bigint) from public, anon;
revoke all on function public.apply_payment(text, text, text, bigint, jsonb) from public, anon;
grant execute on function public.is_admin() to authenticated;
grant execute on function public.reset_battery() to authenticated;
grant execute on function public.record_incoming() to authenticated;
grant execute on function public.fund_payer(bigint) to authenticated;
grant execute on function public.apply_payment(text, text, text, bigint, jsonb) to authenticated;

-- Onboarding asistido. El promotor lee solo el caso saneado.
-- El expediente Didit vive en kyc_dossiers y no tiene grant al navegador.

create table if not exists public.promoters (
  user_id uuid primary key references auth.users (id) on delete cascade,
  email text not null unique,
  login text,
  created_at timestamptz not null default now()
);

alter table public.promoters add column if not exists login text;
create unique index if not exists promoters_login_key on public.promoters (lower(login));

create table if not exists public.onboarding_cases (
  id uuid primary key default gen_random_uuid(),
  promoter_id uuid not null references public.promoters (user_id) on delete cascade,
  first_name text,
  last_name text,
  didit_status text not null default 'Not Started',
  apt_for_cvu boolean not null default false,
  failure_reasons text[] not null default '{}',
  confirmed_at timestamptz,
  didit_session_id text,
  resume_hash text,
  created_at timestamptz not null default now()
);

alter table public.onboarding_cases add column if not exists resume_hash text;

create table if not exists public.kyc_dossiers (
  session_id text primary key,
  case_id uuid not null references public.onboarding_cases (id) on delete cascade,
  payload jsonb not null,
  corrected jsonb,
  updated_at timestamptz not null default now()
);

create index if not exists onboarding_cases_promoter_idx
  on public.onboarding_cases (promoter_id, created_at desc);

alter table public.promoters enable row level security;
alter table public.onboarding_cases enable row level security;
alter table public.kyc_dossiers enable row level security;

drop policy if exists promoters_self on public.promoters;
create policy promoters_self on public.promoters
  for select to authenticated
  using (user_id = auth.uid());

drop policy if exists promoters_admin_read on public.promoters;
create policy promoters_admin_read on public.promoters
  for select to authenticated
  using (public.is_admin());

drop policy if exists cases_promoter_read on public.onboarding_cases;
create policy cases_promoter_read on public.onboarding_cases
  for select to authenticated
  using (promoter_id = auth.uid());

revoke all on public.promoters, public.onboarding_cases, public.kyc_dossiers from anon, authenticated, public;
grant select on public.promoters, public.onboarding_cases to authenticated;

-- La lectura del DNI y del expediente no sale de estas funciones.
-- Quvex se activa recién cuando se cree la CVU; hasta entonces la ficha vive acá.

create or replace function public.capture_preview(p_case uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_case public.onboarding_cases%rowtype;
  v_payload jsonb;
  v_corrected jsonb;
  v_check jsonb;
begin
  select * into v_case from public.onboarding_cases where id = p_case;
  if not found or v_case.promoter_id is distinct from auth.uid() then
    raise exception 'entrevista no encontrada';
  end if;
  if v_case.confirmed_at is not null then
    return jsonb_build_object('confirmed', true, 'first_name', v_case.first_name, 'last_name', v_case.last_name);
  end if;
  select payload, corrected into v_payload, v_corrected
  from public.kyc_dossiers
  where case_id = p_case
  order by updated_at desc
  limit 1;
  v_check := coalesce(v_payload->'id_verifications'->0, '{}'::jsonb);
  return jsonb_build_object(
    'confirmed', false,
    'didit_status', v_case.didit_status,
    'first_name', coalesce(v_corrected->>'first_name', v_case.first_name, v_check->>'first_name'),
    'last_name', coalesce(v_corrected->>'last_name', v_case.last_name, v_check->>'last_name'),
    'document_number', coalesce(v_corrected->>'document_number', v_check->>'document_number')
  );
end;
$$;

create or replace function public.confirm_capture(p_case uuid, p_first text, p_last text, p_dni text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_case public.onboarding_cases%rowtype;
  v_first text := btrim(p_first);
  v_last text := btrim(p_last);
  v_dni text := regexp_replace(coalesce(p_dni, ''), '\D', '', 'g');
begin
  if char_length(v_first) < 2 or char_length(v_first) > 80 or char_length(v_last) < 2 or char_length(v_last) > 80 then
    raise exception 'el nombre y el apellido tienen que estar completos';
  end if;
  if v_dni !~ '^[0-9]{7,8}$' then
    raise exception 'el DNI tiene que tener 7 u 8 dígitos';
  end if;
  select * into v_case from public.onboarding_cases where id = p_case for update;
  if not found or v_case.promoter_id is distinct from auth.uid() then
    raise exception 'entrevista no encontrada';
  end if;
  update public.kyc_dossiers
    set corrected = jsonb_build_object('first_name', v_first, 'last_name', v_last, 'document_number', v_dni),
        updated_at = now()
    where case_id = p_case;
  if not found then
    insert into public.kyc_dossiers (session_id, case_id, payload, corrected)
    values ('confirm-' || p_case::text, p_case, '{}'::jsonb, jsonb_build_object('first_name', v_first, 'last_name', v_last, 'document_number', v_dni));
  end if;
  update public.onboarding_cases
    set first_name = v_first,
        last_name = v_last,
        confirmed_at = now(),
        apt_for_cvu = didit_status = 'Approved'
    where id = p_case;
  return jsonb_build_object('confirmed', true, 'first_name', v_first, 'last_name', v_last, 'apt_for_cvu', v_case.didit_status = 'Approved');
end;
$$;

revoke all on function public.capture_preview(uuid) from public, anon;
revoke all on function public.confirm_capture(uuid, text, text, text) from public, anon;
grant execute on function public.capture_preview(uuid) to authenticated;
grant execute on function public.confirm_capture(uuid, text, text, text) to authenticated;

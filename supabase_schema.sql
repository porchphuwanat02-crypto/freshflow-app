create table if not exists public.freshflow_marketplace_settings (
  id smallint primary key default 1 check (id = 1),
  commission_rate numeric(5, 2) not null default 3.00
    check (commission_rate between 0 and 100),
  updated_at timestamptz not null default now()
);

insert into public.freshflow_marketplace_settings (id, commission_rate)
values (1, 3.00)
on conflict (id) do nothing;

alter table public.freshflow_marketplace_settings enable row level security;

drop policy if exists "Anyone can read marketplace commission rate"
  on public.freshflow_marketplace_settings;
create policy "Anyone can read marketplace commission rate"
  on public.freshflow_marketplace_settings
  for select
  to anon, authenticated
  using (true);

revoke all on public.freshflow_marketplace_settings from anon, authenticated;
grant select on public.freshflow_marketplace_settings to anon, authenticated;

create table if not exists public.freshflow_marketplace_suppliers (
  user_id uuid primary key references auth.users (id) on delete cascade,
  business_name text not null check (char_length(btrim(business_name)) between 1 and 160),
  public_contact text not null default '' check (char_length(public_contact) <= 160),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.freshflow_marketplace_suppliers enable row level security;

drop policy if exists "Visitors can read active marketplace suppliers"
  on public.freshflow_marketplace_suppliers;
create policy "Visitors can read active marketplace suppliers"
  on public.freshflow_marketplace_suppliers
  for select
  to anon, authenticated
  using (is_active or auth.uid() = user_id);

drop policy if exists "Suppliers can manage their own marketplace profile"
  on public.freshflow_marketplace_suppliers;
create policy "Suppliers can manage their own marketplace profile"
  on public.freshflow_marketplace_suppliers
  for all
  to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

revoke all on public.freshflow_marketplace_suppliers from anon, authenticated;
grant select on public.freshflow_marketplace_suppliers to anon, authenticated;
grant insert, update on public.freshflow_marketplace_suppliers to authenticated;

create table if not exists public.freshflow_marketplace_products (
  id uuid primary key default gen_random_uuid(),
  seller_id uuid not null references public.freshflow_marketplace_suppliers (user_id),
  name text not null check (char_length(btrim(name)) between 1 and 160),
  category text not null check (char_length(btrim(category)) between 1 and 80),
  unit text not null check (char_length(btrim(unit)) between 1 and 30),
  description text not null default '' check (char_length(description) <= 1000),
  unit_price numeric(12, 2) not null check (unit_price > 0),
  stock_qty numeric(12, 3) not null default 0 check (stock_qty >= 0),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.freshflow_marketplace_products enable row level security;

drop policy if exists "Visitors can read active marketplace products"
  on public.freshflow_marketplace_products;
create policy "Visitors can read active marketplace products"
  on public.freshflow_marketplace_products
  for select
  to anon, authenticated
  using (
    is_active and exists (
      select 1
      from public.freshflow_marketplace_suppliers
      where user_id = seller_id
        and is_active
    )
  );

drop policy if exists "Suppliers can manage their own marketplace products"
  on public.freshflow_marketplace_products;
create policy "Suppliers can manage their own marketplace products"
  on public.freshflow_marketplace_products
  for all
  to authenticated
  using (auth.uid() = seller_id)
  with check (auth.uid() = seller_id);

revoke all on public.freshflow_marketplace_products from anon, authenticated;
grant select on public.freshflow_marketplace_products to anon, authenticated;
grant insert, update on public.freshflow_marketplace_products to authenticated;

create table if not exists public.freshflow_marketplace_orders (
  id uuid primary key default gen_random_uuid(),
  buyer_id uuid not null references auth.users (id),
  seller_id uuid not null references public.freshflow_marketplace_suppliers (user_id),
  product_id uuid not null references public.freshflow_marketplace_products (id),
  buyer_store text not null default '',
  product_name text not null default '',
  unit text not null default '',
  quantity numeric(12, 3) not null check (quantity > 0),
  unit_price numeric(12, 2) not null default 0,
  subtotal numeric(12, 2) not null default 0,
  commission_rate numeric(5, 2) not null default 3.00,
  commission_amount numeric(12, 2) not null default 0,
  seller_net numeric(12, 2) not null default 0,
  status text not null default 'requested'
    check (status in ('requested', 'confirmed', 'fulfilled', 'cancelled')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.freshflow_marketplace_orders enable row level security;

drop policy if exists "Buyers and sellers can read their marketplace orders"
  on public.freshflow_marketplace_orders;
create policy "Buyers and sellers can read their marketplace orders"
  on public.freshflow_marketplace_orders
  for select
  to authenticated
  using (auth.uid() = buyer_id or auth.uid() = seller_id);

drop policy if exists "Buyers can create marketplace orders"
  on public.freshflow_marketplace_orders;
create policy "Buyers can create marketplace orders"
  on public.freshflow_marketplace_orders
  for insert
  to authenticated
  with check (auth.uid() = buyer_id);

drop policy if exists "Buyers and sellers can update marketplace order status"
  on public.freshflow_marketplace_orders;
create policy "Buyers and sellers can update marketplace order status"
  on public.freshflow_marketplace_orders
  for update
  to authenticated
  using (auth.uid() = buyer_id or auth.uid() = seller_id)
  with check (auth.uid() = buyer_id or auth.uid() = seller_id);

revoke all on public.freshflow_marketplace_orders from anon, authenticated;
grant select, insert on public.freshflow_marketplace_orders to authenticated;
grant update (status) on public.freshflow_marketplace_orders to authenticated;

create or replace function public.prepare_freshflow_marketplace_order()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  product_row public.freshflow_marketplace_products%rowtype;
  current_commission_rate numeric(5, 2);
begin
  if tg_op = 'INSERT' then
    if auth.uid() is null then
      raise exception 'Sign in is required to place an order';
    end if;

    if new.buyer_id is not null and new.buyer_id <> auth.uid() then
      raise exception 'Buyer must be the current user';
    end if;
    new.buyer_id := auth.uid();

    select * into product_row
    from public.freshflow_marketplace_products
    where id = new.product_id and is_active
    for update;
    if not found then
      raise exception 'Product is unavailable';
    end if;
    if product_row.seller_id = auth.uid() then
      raise exception 'Suppliers cannot order their own products';
    end if;
    if new.quantity is null or new.quantity <= 0 or new.quantity > product_row.stock_qty then
      raise exception 'Requested quantity exceeds available stock';
    end if;

    select commission_rate into current_commission_rate
    from public.freshflow_marketplace_settings
    where id = 1;
    if not found then
      raise exception 'Marketplace commission rate is not configured';
    end if;

    update public.freshflow_marketplace_products
    set stock_qty = stock_qty - new.quantity,
        updated_at = now()
    where id = product_row.id;

    new.seller_id := product_row.seller_id;
    new.product_name := product_row.name;
    new.unit := product_row.unit;
    new.unit_price := product_row.unit_price;
    new.subtotal := round(product_row.unit_price * new.quantity, 2);
    new.commission_rate := current_commission_rate;
    new.commission_amount := round(new.subtotal * current_commission_rate / 100, 2);
    new.seller_net := new.subtotal - new.commission_amount;
    new.status := 'requested';
    new.updated_at := now();
    return new;
  end if;

  if auth.uid() = old.buyer_id then
    if old.status <> 'requested' or new.status <> 'cancelled' then
      raise exception 'Buyers can only cancel requested orders';
    end if;
  elsif auth.uid() = old.seller_id then
    if not (
      (old.status = 'requested' and new.status in ('confirmed', 'cancelled'))
      or (old.status = 'confirmed' and new.status in ('fulfilled', 'cancelled'))
    ) then
      raise exception 'Invalid seller order status transition';
    end if;
  else
    raise exception 'Only the buyer or seller can update this order';
  end if;

  if new.status = 'cancelled' then
    update public.freshflow_marketplace_products
    set stock_qty = stock_qty + old.quantity,
        updated_at = now()
    where id = old.product_id;
  end if;

  new.updated_at := now();
  return new;
end;
$$;

revoke all on function public.prepare_freshflow_marketplace_order() from public, anon, authenticated;
grant execute on function public.prepare_freshflow_marketplace_order() to authenticated;

drop trigger if exists prepare_freshflow_marketplace_order
  on public.freshflow_marketplace_orders;
create trigger prepare_freshflow_marketplace_order
  before insert or update of status on public.freshflow_marketplace_orders
  for each row
  execute function public.prepare_freshflow_marketplace_order();

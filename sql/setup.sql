-- ============================================================================
--  RESI-STORE · POS + MATRIZ  ·  setup.sql  (INSTALACION COMPLETA DESDE CERO)
--  Incluye: tablas, venta ATOMICA (a prueba de sobreventa), ticket_id,
--  gavetas 3D (444) + mapeo SKU->gaveta, vistas, funciones, realtime y RLS.
--  Ejecutar TODO de una vez en: Supabase -> SQL Editor -> New query -> Run.
-- ============================================================================

-- ############################################################################
--  1) TABLAS
-- ############################################################################
create sequence if not exists public.seq_local;

create table if not exists public.locales (
  id               text primary key default ('PDV-' || lpad(nextval('public.seq_local')::text, 3, '0')),
  nombre_sucursal  text not null,
  nombre_encargado text not null,
  telefono         text,
  email            text unique not null,
  password         text not null,
  comision_pct     numeric(5,2) not null default 10,
  activo           boolean not null default true,
  created_at       timestamptz not null default now()
);

create table if not exists public.gavetas (
  id text primary key, columna smallint not null, sub smallint not null,
  fila smallint not null, pos smallint not null,
  tipo text not null default 'normal', ancho smallint not null default 1
);

create table if not exists public.productos (
  id          bigint generated always as identity primary key,
  sku         text unique not null,
  nombre      text not null,
  precio      numeric(10,2) not null default 0,
  costo_repos numeric(10,2) not null default 0,
  gaveta_id   text references public.gavetas(id),
  activo      boolean not null default true,
  created_at  timestamptz not null default now()
);
create index if not exists idx_productos_sku    on public.productos (lower(sku));
create index if not exists idx_productos_nombre on public.productos (lower(nombre));
create index if not exists idx_productos_gaveta on public.productos (gaveta_id);

create table if not exists public.inventario (
  id bigint generated always as identity primary key,
  local_id text not null references public.locales(id) on delete cascade,
  sku text not null references public.productos(sku) on delete cascade,
  stock integer not null default 0,
  stock_min integer not null default 5,
  updated_at timestamptz not null default now(),
  unique (local_id, sku)
);
create index if not exists idx_inv_local on public.inventario (local_id);
create index if not exists idx_inv_sku   on public.inventario (sku);

create table if not exists public.ventas (
  id bigint generated always as identity primary key,
  local_id text not null references public.locales(id),
  sku text not null references public.productos(sku),
  nombre text not null,
  cantidad integer not null check (cantidad > 0),
  precio_unit numeric(10,2) not null,
  total numeric(10,2) not null,
  recibido numeric(10,2) not null default 0,
  cambio numeric(10,2) not null default 0,
  comision_pct numeric(5,2) not null default 0,
  costo_unit numeric(10,2) not null default 0,
  comision_monto numeric(10,2) not null default 0,
  pago_matriz numeric(10,2) not null default 0,
  ganancia_matriz numeric(10,2) not null default 0,
  ticket_id uuid,
  created_at timestamptz not null default now()
);
create index if not exists idx_ventas_local  on public.ventas (local_id);
create index if not exists idx_ventas_fecha  on public.ventas (created_at desc);
create index if not exists idx_ventas_ticket on public.ventas (ticket_id);

create table if not exists public.arqueos (
  id bigint generated always as identity primary key,
  local_id text not null references public.locales(id),
  sku text not null,
  stock_sistema integer not null,
  conteo_fisico integer not null,
  diferencia integer not null,
  valor_reposicion numeric(10,2) not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists idx_arqueos_local on public.arqueos (local_id, created_at desc);

-- ############################################################################
--  2) TRIGGERS
-- ############################################################################
create or replace function public.fn_calc_venta()
returns trigger language plpgsql as $$
declare v_com numeric; v_costo numeric;
begin
  select coalesce(comision_pct,0) into v_com   from public.locales   where id  = new.local_id;
  select coalesce(costo_repos,0)  into v_costo from public.productos where sku = new.sku;
  new.comision_pct    := coalesce(v_com,0);
  new.costo_unit      := coalesce(v_costo,0);
  new.comision_monto  := round(new.total * coalesce(v_com,0)/100, 2);
  new.pago_matriz     := new.total - new.comision_monto;
  new.ganancia_matriz := new.pago_matriz - (new.costo_unit * new.cantidad);
  return new;
end; $$;
drop trigger if exists trg_calc_venta on public.ventas;
create trigger trg_calc_venta before insert on public.ventas
  for each row execute function public.fn_calc_venta();

create or replace function public.fn_descontar_stock()
returns trigger language plpgsql as $$
begin
  update public.inventario
     set stock = stock - new.cantidad, updated_at = now()
   where local_id = new.local_id and sku = new.sku and stock >= new.cantidad;
  if not found then
    raise exception 'STOCK_INSUFICIENTE: % (solicitado %)', new.sku, new.cantidad;
  end if;
  return new;
end; $$;
drop trigger if exists trg_descontar_stock on public.ventas;
create trigger trg_descontar_stock after insert on public.ventas
  for each row execute function public.fn_descontar_stock();

-- ############################################################################
--  3) VISTAS  (v_inventario incluye gaveta_id; orden correcto de dependencias)
-- ############################################################################
drop view if exists public.v_alarmas_stock;
drop view if exists public.v_inventario;
create view public.v_inventario as
select i.local_id, l.nombre_sucursal, i.sku, p.nombre, p.precio, p.costo_repos, p.gaveta_id,
  i.stock, i.stock_min,
  case when i.stock <= 0 then 'AGOTADO'
       when i.stock < i.stock_min then 'BAJO_MINIMO'
       when i.stock <= i.stock_min*1.2 then 'CERCA_MINIMO'
       else 'NORMAL' end as estado
from public.inventario i
join public.productos p on p.sku = i.sku
join public.locales   l on l.id  = i.local_id;

create view public.v_alarmas_stock as
select local_id, nombre_sucursal, sku, nombre, stock, stock_min, estado
from public.v_inventario where estado <> 'NORMAL' order by stock;

drop view if exists public.v_locales;
create view public.v_locales as
select id, nombre_sucursal, nombre_encargado, telefono, email, comision_pct, activo, created_at
from public.locales order by nombre_sucursal;

drop view if exists public.v_cortes_quincena;
create view public.v_cortes_quincena as
with base as (
  select local_id, date_trunc('month', created_at)::date as mes,
    extract(year from created_at)::int as yy, extract(month from created_at)::int as mm,
    case when extract(day from created_at) <= 15 then 1 else 2 end as q,
    total, comision_monto, pago_matriz, ganancia_matriz
  from public.ventas
)
select local_id, to_char(mes,'YYYY-MM') as ym, q,
  case when q=1 then make_date(yy,mm,1) else make_date(yy,mm,16) end as periodo_inicio,
  case when q=1 then make_date(yy,mm,15) else (mes + interval '1 month - 1 day')::date end as periodo_fin,
  count(*) as num_ventas, sum(total) as venta_total,
  sum(comision_monto) as ganancia_local, sum(pago_matriz) as pago_matriz,
  sum(ganancia_matriz) as ganancia_matriz
from base group by local_id, mes, yy, mm, q
order by periodo_inicio desc;

-- ############################################################################
--  4) FUNCIONES (RPC) · security definer
-- ############################################################################
create or replace function public.fn_login_local(p_email text, p_password text)
returns table(id text, nombre_sucursal text, nombre_encargado text)
language sql security definer set search_path = public as $$
  select id, nombre_sucursal, nombre_encargado from public.locales
  where lower(email)=lower(p_email) and password=p_password and activo=true;
$$;

create or replace function public.fn_crear_local(
  p_sucursal text, p_encargado text, p_telefono text,
  p_email text, p_password text, p_comision numeric default 10)
returns text language plpgsql security definer set search_path = public as $$
declare v_id text;
begin
  insert into public.locales(nombre_sucursal, nombre_encargado, telefono, email, password, comision_pct)
  values (p_sucursal, p_encargado, p_telefono, lower(p_email), p_password, coalesce(p_comision,10))
  returning id into v_id; return v_id;
end; $$;

create or replace function public.fn_reabastecer(p_local text, p_sku text, p_cant integer)
returns integer language plpgsql security definer set search_path = public as $$
declare v_new integer;
begin
  insert into public.inventario(local_id, sku, stock, stock_min)
  values (p_local, p_sku, greatest(0,p_cant), 5)
  on conflict (local_id, sku)
    do update set stock = public.inventario.stock + greatest(0,p_cant), updated_at = now()
  returning stock into v_new; return v_new;
end; $$;

create or replace function public.fn_arqueo_aplicar(p_local text, p_sku text, p_conteo integer)
returns integer language plpgsql security definer set search_path = public as $$
declare v_prev integer; v_costo numeric; v_diff integer;
begin
  select i.stock, p.costo_repos into v_prev, v_costo
  from public.inventario i join public.productos p on p.sku = i.sku
  where i.local_id = p_local and i.sku = p_sku;
  if v_prev is null then v_prev := 0; v_costo := 0; end if;
  v_diff := p_conteo - v_prev;
  insert into public.inventario(local_id, sku, stock, stock_min)
  values (p_local, p_sku, greatest(0,p_conteo), 5)
  on conflict (local_id, sku) do update set stock = greatest(0,p_conteo), updated_at = now();
  insert into public.arqueos(local_id, sku, stock_sistema, conteo_fisico, diferencia, valor_reposicion)
  values (p_local, p_sku, v_prev, p_conteo, v_diff,
          case when v_diff < 0 then abs(v_diff)*coalesce(v_costo,0) else 0 end);
  return v_diff;
end; $$;

create or replace function public.fn_asignar_gaveta(p_sku text, p_gaveta text)
returns void language sql security definer set search_path=public as $$
  update public.productos set gaveta_id = p_gaveta where sku = p_sku;
$$;

create or replace function public.fn_vender(
  p_local text, p_recibido numeric, p_cambio numeric, p_items jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_ticket uuid := gen_random_uuid(); it jsonb; v_id bigint; v_ids bigint[] := '{}'; v_first boolean := true;
begin
  if p_items is null or jsonb_array_length(p_items) = 0 then raise exception 'CARRITO_VACIO'; end if;
  for it in select value from jsonb_array_elements(p_items) loop
    insert into public.ventas(local_id, sku, nombre, cantidad, precio_unit, total, recibido, cambio, ticket_id)
    values (p_local, it->>'sku', it->>'nombre', (it->>'cantidad')::int, (it->>'precio')::numeric,
            (it->>'precio')::numeric * (it->>'cantidad')::int,
            case when v_first then coalesce(p_recibido,0) else 0 end,
            case when v_first then coalesce(p_cambio,0)   else 0 end, v_ticket)
    returning id into v_id;
    v_ids := array_append(v_ids, v_id); v_first := false;
  end loop;
  return jsonb_build_object('ticket_id', v_ticket, 'ids', to_jsonb(v_ids));
end; $$;

grant execute on function public.fn_login_local(text,text)                        to anon, authenticated;
grant execute on function public.fn_crear_local(text,text,text,text,text,numeric)  to anon, authenticated;
grant execute on function public.fn_reabastecer(text,text,integer)                to anon, authenticated;
grant execute on function public.fn_arqueo_aplicar(text,text,integer)             to anon, authenticated;
grant execute on function public.fn_asignar_gaveta(text,text)                     to anon, authenticated;
grant execute on function public.fn_vender(text,numeric,numeric,jsonb)            to anon, authenticated;
grant select on public.v_inventario, public.v_alarmas_stock, public.v_locales, public.v_cortes_quincena, public.gavetas
  to anon, authenticated;

-- ############################################################################
--  5) REALTIME
-- ############################################################################
do $$ begin
  begin alter publication supabase_realtime add table public.ventas;     exception when others then null; end;
  begin alter publication supabase_realtime add table public.inventario; exception when others then null; end;
end $$;

-- ############################################################################
--  6) RLS (PILOTO)
-- ############################################################################
alter table public.locales    enable row level security;
alter table public.productos  enable row level security;
alter table public.inventario enable row level security;
alter table public.ventas     enable row level security;
alter table public.arqueos    enable row level security;
alter table public.gavetas    enable row level security;

drop policy if exists p_prod_all on public.productos;
create policy p_prod_all on public.productos for all using (true) with check (true);
drop policy if exists p_inv_all on public.inventario;
create policy p_inv_all on public.inventario for all using (true) with check (true);
drop policy if exists p_arq_all on public.arqueos;
create policy p_arq_all on public.arqueos for all using (true) with check (true);
drop policy if exists p_gav_read on public.gavetas;
create policy p_gav_read on public.gavetas for select using (true);
drop policy if exists p_ventas_read on public.ventas;
create policy p_ventas_read on public.ventas for select using (true);
drop policy if exists p_ventas_insert on public.ventas;
create policy p_ventas_insert on public.ventas for insert with check (true);
-- locales: sin politicas para anon (password protegido); acceso via funciones/vista.

-- ############################################################################
--  7) SEED de las 444 gavetas (mueble real)
-- ############################################################################
insert into public.gavetas (id, columna, sub, fila, pos, tipo, ancho) values
('C1-S1-R1-P1',1,1,1,1,'normal',1),
('C1-S1-R1-P2',1,1,1,2,'normal',1),
('C1-S1-R1-P3',1,1,1,3,'normal',1),
('C1-S1-R1-P4',1,1,1,4,'normal',1),
('C1-S1-R1-P5',1,1,1,5,'normal',1),
('C1-S1-R1-P6',1,1,1,6,'normal',1),
('C1-S1-R1-P7',1,1,1,7,'normal',1),
('C1-S1-R1-P8',1,1,1,8,'normal',1),
('C1-S1-R2-P1',1,1,2,1,'normal',1),
('C1-S1-R2-P2',1,1,2,2,'normal',1),
('C1-S1-R2-P3',1,1,2,3,'normal',1),
('C1-S1-R2-P4',1,1,2,4,'normal',1),
('C1-S1-R2-P5',1,1,2,5,'normal',1),
('C1-S1-R2-P6',1,1,2,6,'normal',1),
('C1-S1-R2-P7',1,1,2,7,'normal',1),
('C1-S1-R2-P8',1,1,2,8,'normal',1),
('C1-S1-R3-P1',1,1,3,1,'normal',1),
('C1-S1-R3-P2',1,1,3,2,'normal',1),
('C1-S1-R3-P3',1,1,3,3,'normal',1),
('C1-S1-R3-P4',1,1,3,4,'normal',1),
('C1-S1-R3-P5',1,1,3,5,'normal',1),
('C1-S1-R3-P6',1,1,3,6,'normal',1),
('C1-S1-R3-P7',1,1,3,7,'normal',1),
('C1-S1-R3-P8',1,1,3,8,'normal',1),
('C1-S1-R4-P1',1,1,4,1,'normal',1),
('C1-S1-R4-P2',1,1,4,2,'normal',1),
('C1-S1-R4-P3',1,1,4,3,'normal',1),
('C1-S1-R4-P4',1,1,4,4,'normal',1),
('C1-S1-R4-P5',1,1,4,5,'normal',1),
('C1-S1-R4-P6',1,1,4,6,'normal',1),
('C1-S1-R4-P7',1,1,4,7,'normal',1),
('C1-S1-R4-P8',1,1,4,8,'normal',1),
('C1-S1-R5-P1',1,1,5,1,'wide',2),
('C1-S1-R5-P2',1,1,5,2,'wide',2),
('C1-S1-R5-P3',1,1,5,3,'wide',2),
('C1-S1-R5-P4',1,1,5,4,'wide',2),
('C1-S1-R6-P1',1,1,6,1,'wide',2),
('C1-S1-R6-P2',1,1,6,2,'wide',2),
('C1-S1-R6-P3',1,1,6,3,'wide',2),
('C1-S1-R6-P4',1,1,6,4,'wide',2),
('C1-S1-R7-P1',1,1,7,1,'wide',2),
('C1-S1-R7-P2',1,1,7,2,'wide',2),
('C1-S1-R7-P3',1,1,7,3,'wide',2),
('C1-S1-R7-P4',1,1,7,4,'wide',2),
('C1-S2-R1-P1',1,2,1,1,'normal',1),
('C1-S2-R1-P2',1,2,1,2,'normal',1),
('C1-S2-R1-P3',1,2,1,3,'normal',1),
('C1-S2-R1-P4',1,2,1,4,'normal',1),
('C1-S2-R1-P5',1,2,1,5,'normal',1),
('C1-S2-R1-P6',1,2,1,6,'normal',1),
('C1-S2-R1-P7',1,2,1,7,'normal',1),
('C1-S2-R1-P8',1,2,1,8,'normal',1),
('C1-S2-R2-P1',1,2,2,1,'normal',1),
('C1-S2-R2-P2',1,2,2,2,'normal',1),
('C1-S2-R2-P3',1,2,2,3,'normal',1),
('C1-S2-R2-P4',1,2,2,4,'normal',1),
('C1-S2-R2-P5',1,2,2,5,'normal',1),
('C1-S2-R2-P6',1,2,2,6,'normal',1),
('C1-S2-R2-P7',1,2,2,7,'normal',1),
('C1-S2-R2-P8',1,2,2,8,'normal',1),
('C1-S2-R3-P1',1,2,3,1,'normal',1),
('C1-S2-R3-P2',1,2,3,2,'normal',1),
('C1-S2-R3-P3',1,2,3,3,'normal',1),
('C1-S2-R3-P4',1,2,3,4,'normal',1),
('C1-S2-R3-P5',1,2,3,5,'normal',1),
('C1-S2-R3-P6',1,2,3,6,'normal',1),
('C1-S2-R3-P7',1,2,3,7,'normal',1),
('C1-S2-R3-P8',1,2,3,8,'normal',1),
('C1-S2-R4-P1',1,2,4,1,'normal',1),
('C1-S2-R4-P2',1,2,4,2,'normal',1),
('C1-S2-R4-P3',1,2,4,3,'normal',1),
('C1-S2-R4-P4',1,2,4,4,'normal',1),
('C1-S2-R4-P5',1,2,4,5,'normal',1),
('C1-S2-R4-P6',1,2,4,6,'normal',1),
('C1-S2-R4-P7',1,2,4,7,'normal',1),
('C1-S2-R4-P8',1,2,4,8,'normal',1),
('C1-S2-R5-P1',1,2,5,1,'normal',1),
('C1-S2-R5-P2',1,2,5,2,'normal',1),
('C1-S2-R5-P3',1,2,5,3,'normal',1),
('C1-S2-R5-P4',1,2,5,4,'normal',1),
('C1-S2-R5-P5',1,2,5,5,'normal',1),
('C1-S2-R5-P6',1,2,5,6,'normal',1),
('C1-S2-R5-P7',1,2,5,7,'normal',1),
('C1-S2-R5-P8',1,2,5,8,'normal',1),
('C1-S2-R6-P1',1,2,6,1,'normal',1),
('C1-S2-R6-P2',1,2,6,2,'normal',1),
('C1-S2-R6-P3',1,2,6,3,'normal',1),
('C1-S2-R6-P4',1,2,6,4,'normal',1),
('C1-S2-R6-P5',1,2,6,5,'normal',1),
('C1-S2-R6-P6',1,2,6,6,'normal',1),
('C1-S2-R6-P7',1,2,6,7,'normal',1),
('C1-S2-R6-P8',1,2,6,8,'normal',1),
('C1-S2-R7-P1',1,2,7,1,'normal',1),
('C1-S2-R7-P2',1,2,7,2,'normal',1),
('C1-S2-R7-P3',1,2,7,3,'normal',1),
('C1-S2-R7-P4',1,2,7,4,'normal',1),
('C1-S2-R7-P5',1,2,7,5,'normal',1),
('C1-S2-R7-P6',1,2,7,6,'normal',1),
('C1-S2-R7-P7',1,2,7,7,'normal',1),
('C1-S2-R7-P8',1,2,7,8,'normal',1),
('C1-S2-R8-P1',1,2,8,1,'normal',1),
('C1-S2-R8-P2',1,2,8,2,'normal',1),
('C1-S2-R8-P3',1,2,8,3,'normal',1),
('C1-S2-R8-P4',1,2,8,4,'normal',1),
('C1-S2-R8-P5',1,2,8,5,'normal',1),
('C1-S2-R8-P6',1,2,8,6,'normal',1),
('C1-S2-R8-P7',1,2,8,7,'normal',1),
('C1-S2-R8-P8',1,2,8,8,'normal',1),
('C1-S3-R1-P1',1,3,1,1,'normal',1),
('C1-S3-R1-P2',1,3,1,2,'normal',1),
('C1-S3-R1-P3',1,3,1,3,'normal',1),
('C1-S3-R1-P4',1,3,1,4,'normal',1),
('C1-S3-R1-P5',1,3,1,5,'normal',1),
('C1-S3-R1-P6',1,3,1,6,'normal',1),
('C1-S3-R1-P7',1,3,1,7,'normal',1),
('C1-S3-R1-P8',1,3,1,8,'normal',1),
('C1-S3-R2-P1',1,3,2,1,'normal',1),
('C1-S3-R2-P2',1,3,2,2,'normal',1),
('C1-S3-R2-P3',1,3,2,3,'normal',1),
('C1-S3-R2-P4',1,3,2,4,'normal',1),
('C1-S3-R2-P5',1,3,2,5,'normal',1),
('C1-S3-R2-P6',1,3,2,6,'normal',1),
('C1-S3-R2-P7',1,3,2,7,'normal',1),
('C1-S3-R2-P8',1,3,2,8,'normal',1),
('C1-S3-R3-P1',1,3,3,1,'normal',1),
('C1-S3-R3-P2',1,3,3,2,'normal',1),
('C1-S3-R3-P3',1,3,3,3,'normal',1),
('C1-S3-R3-P4',1,3,3,4,'normal',1),
('C1-S3-R3-P5',1,3,3,5,'normal',1),
('C1-S3-R3-P6',1,3,3,6,'normal',1),
('C1-S3-R3-P7',1,3,3,7,'normal',1),
('C1-S3-R3-P8',1,3,3,8,'normal',1),
('C1-S3-R4-P1',1,3,4,1,'normal',1),
('C1-S3-R4-P2',1,3,4,2,'normal',1),
('C1-S3-R4-P3',1,3,4,3,'normal',1),
('C1-S3-R4-P4',1,3,4,4,'normal',1),
('C1-S3-R4-P5',1,3,4,5,'normal',1),
('C1-S3-R4-P6',1,3,4,6,'normal',1),
('C1-S3-R4-P7',1,3,4,7,'normal',1),
('C1-S3-R4-P8',1,3,4,8,'normal',1),
('C1-S3-R5-P1',1,3,5,1,'wide',2),
('C1-S3-R5-P2',1,3,5,2,'wide',2),
('C1-S3-R5-P3',1,3,5,3,'wide',2),
('C1-S3-R5-P4',1,3,5,4,'wide',2),
('C1-S3-R6-P1',1,3,6,1,'wide',2),
('C1-S3-R6-P2',1,3,6,2,'wide',2),
('C1-S3-R6-P3',1,3,6,3,'wide',2),
('C1-S3-R6-P4',1,3,6,4,'wide',2),
('C1-S3-R7-P1',1,3,7,1,'wide',2),
('C1-S3-R7-P2',1,3,7,2,'wide',2),
('C1-S3-R7-P3',1,3,7,3,'wide',2),
('C1-S3-R7-P4',1,3,7,4,'wide',2),
('C2-S1-R1-P1',2,1,1,1,'normal',1),
('C2-S1-R1-P2',2,1,1,2,'normal',1),
('C2-S1-R1-P3',2,1,1,3,'normal',1),
('C2-S1-R1-P4',2,1,1,4,'normal',1),
('C2-S1-R1-P5',2,1,1,5,'normal',1),
('C2-S1-R1-P6',2,1,1,6,'normal',1),
('C2-S1-R1-P7',2,1,1,7,'normal',1),
('C2-S1-R1-P8',2,1,1,8,'normal',1),
('C2-S1-R2-P1',2,1,2,1,'normal',1),
('C2-S1-R2-P2',2,1,2,2,'normal',1),
('C2-S1-R2-P3',2,1,2,3,'normal',1),
('C2-S1-R2-P4',2,1,2,4,'normal',1),
('C2-S1-R2-P5',2,1,2,5,'normal',1),
('C2-S1-R2-P6',2,1,2,6,'normal',1),
('C2-S1-R2-P7',2,1,2,7,'normal',1),
('C2-S1-R2-P8',2,1,2,8,'normal',1),
('C2-S1-R3-P1',2,1,3,1,'normal',1),
('C2-S1-R3-P2',2,1,3,2,'normal',1),
('C2-S1-R3-P3',2,1,3,3,'normal',1),
('C2-S1-R3-P4',2,1,3,4,'normal',1),
('C2-S1-R3-P5',2,1,3,5,'normal',1),
('C2-S1-R3-P6',2,1,3,6,'normal',1),
('C2-S1-R3-P7',2,1,3,7,'normal',1),
('C2-S1-R3-P8',2,1,3,8,'normal',1),
('C2-S1-R4-P1',2,1,4,1,'normal',1),
('C2-S1-R4-P2',2,1,4,2,'normal',1),
('C2-S1-R4-P3',2,1,4,3,'normal',1),
('C2-S1-R4-P4',2,1,4,4,'normal',1),
('C2-S1-R4-P5',2,1,4,5,'normal',1),
('C2-S1-R4-P6',2,1,4,6,'normal',1),
('C2-S1-R4-P7',2,1,4,7,'normal',1),
('C2-S1-R4-P8',2,1,4,8,'normal',1),
('C2-S1-R5-P1',2,1,5,1,'wide',2),
('C2-S1-R5-P2',2,1,5,2,'wide',2),
('C2-S1-R5-P3',2,1,5,3,'wide',2),
('C2-S1-R5-P4',2,1,5,4,'wide',2),
('C2-S1-R6-P1',2,1,6,1,'wide',2),
('C2-S1-R6-P2',2,1,6,2,'wide',2),
('C2-S1-R6-P3',2,1,6,3,'wide',2),
('C2-S1-R6-P4',2,1,6,4,'wide',2),
('C2-S1-R7-P1',2,1,7,1,'wide',2),
('C2-S1-R7-P2',2,1,7,2,'wide',2),
('C2-S1-R7-P3',2,1,7,3,'wide',2),
('C2-S1-R7-P4',2,1,7,4,'wide',2),
('C2-S2-R1-P1',2,2,1,1,'normal',1),
('C2-S2-R1-P2',2,2,1,2,'normal',1),
('C2-S2-R1-P3',2,2,1,3,'normal',1),
('C2-S2-R1-P4',2,2,1,4,'normal',1),
('C2-S2-R1-P5',2,2,1,5,'normal',1),
('C2-S2-R1-P6',2,2,1,6,'normal',1),
('C2-S2-R1-P7',2,2,1,7,'normal',1),
('C2-S2-R1-P8',2,2,1,8,'normal',1),
('C2-S2-R2-P1',2,2,2,1,'normal',1),
('C2-S2-R2-P2',2,2,2,2,'normal',1),
('C2-S2-R2-P3',2,2,2,3,'normal',1),
('C2-S2-R2-P4',2,2,2,4,'normal',1),
('C2-S2-R2-P5',2,2,2,5,'normal',1),
('C2-S2-R2-P6',2,2,2,6,'normal',1),
('C2-S2-R2-P7',2,2,2,7,'normal',1),
('C2-S2-R2-P8',2,2,2,8,'normal',1),
('C2-S2-R3-P1',2,2,3,1,'normal',1),
('C2-S2-R3-P2',2,2,3,2,'normal',1),
('C2-S2-R3-P3',2,2,3,3,'normal',1),
('C2-S2-R3-P4',2,2,3,4,'normal',1),
('C2-S2-R3-P5',2,2,3,5,'normal',1),
('C2-S2-R3-P6',2,2,3,6,'normal',1),
('C2-S2-R3-P7',2,2,3,7,'normal',1),
('C2-S2-R3-P8',2,2,3,8,'normal',1),
('C2-S2-R4-P1',2,2,4,1,'normal',1),
('C2-S2-R4-P2',2,2,4,2,'normal',1),
('C2-S2-R4-P3',2,2,4,3,'normal',1),
('C2-S2-R4-P4',2,2,4,4,'normal',1),
('C2-S2-R4-P5',2,2,4,5,'normal',1),
('C2-S2-R4-P6',2,2,4,6,'normal',1),
('C2-S2-R4-P7',2,2,4,7,'normal',1),
('C2-S2-R4-P8',2,2,4,8,'normal',1),
('C2-S2-R5-P1',2,2,5,1,'normal',1),
('C2-S2-R5-P2',2,2,5,2,'normal',1),
('C2-S2-R5-P3',2,2,5,3,'normal',1),
('C2-S2-R5-P4',2,2,5,4,'normal',1),
('C2-S2-R5-P5',2,2,5,5,'normal',1),
('C2-S2-R5-P6',2,2,5,6,'normal',1),
('C2-S2-R5-P7',2,2,5,7,'normal',1),
('C2-S2-R5-P8',2,2,5,8,'normal',1),
('C2-S2-R6-P1',2,2,6,1,'normal',1),
('C2-S2-R6-P2',2,2,6,2,'normal',1),
('C2-S2-R6-P3',2,2,6,3,'normal',1),
('C2-S2-R6-P4',2,2,6,4,'normal',1),
('C2-S2-R6-P5',2,2,6,5,'normal',1),
('C2-S2-R6-P6',2,2,6,6,'normal',1),
('C2-S2-R6-P7',2,2,6,7,'normal',1),
('C2-S2-R6-P8',2,2,6,8,'normal',1),
('C2-S2-R7-P1',2,2,7,1,'normal',1),
('C2-S2-R7-P2',2,2,7,2,'normal',1),
('C2-S2-R7-P3',2,2,7,3,'normal',1),
('C2-S2-R7-P4',2,2,7,4,'normal',1),
('C2-S2-R7-P5',2,2,7,5,'normal',1),
('C2-S2-R7-P6',2,2,7,6,'normal',1),
('C2-S2-R7-P7',2,2,7,7,'normal',1),
('C2-S2-R7-P8',2,2,7,8,'normal',1),
('C2-S2-R8-P1',2,2,8,1,'normal',1),
('C2-S2-R8-P2',2,2,8,2,'normal',1),
('C2-S2-R8-P3',2,2,8,3,'normal',1),
('C2-S2-R8-P4',2,2,8,4,'normal',1),
('C2-S2-R8-P5',2,2,8,5,'normal',1),
('C2-S2-R8-P6',2,2,8,6,'normal',1),
('C2-S2-R8-P7',2,2,8,7,'normal',1),
('C2-S2-R8-P8',2,2,8,8,'normal',1),
('C2-S3-R1-P1',2,3,1,1,'normal',1),
('C2-S3-R1-P2',2,3,1,2,'normal',1),
('C2-S3-R1-P3',2,3,1,3,'normal',1),
('C2-S3-R1-P4',2,3,1,4,'normal',1),
('C2-S3-R1-P5',2,3,1,5,'normal',1),
('C2-S3-R1-P6',2,3,1,6,'normal',1),
('C2-S3-R1-P7',2,3,1,7,'normal',1),
('C2-S3-R1-P8',2,3,1,8,'normal',1),
('C2-S3-R2-P1',2,3,2,1,'normal',1),
('C2-S3-R2-P2',2,3,2,2,'normal',1),
('C2-S3-R2-P3',2,3,2,3,'normal',1),
('C2-S3-R2-P4',2,3,2,4,'normal',1),
('C2-S3-R2-P5',2,3,2,5,'normal',1),
('C2-S3-R2-P6',2,3,2,6,'normal',1),
('C2-S3-R2-P7',2,3,2,7,'normal',1),
('C2-S3-R2-P8',2,3,2,8,'normal',1),
('C2-S3-R3-P1',2,3,3,1,'normal',1),
('C2-S3-R3-P2',2,3,3,2,'normal',1),
('C2-S3-R3-P3',2,3,3,3,'normal',1),
('C2-S3-R3-P4',2,3,3,4,'normal',1),
('C2-S3-R3-P5',2,3,3,5,'normal',1),
('C2-S3-R3-P6',2,3,3,6,'normal',1),
('C2-S3-R3-P7',2,3,3,7,'normal',1),
('C2-S3-R3-P8',2,3,3,8,'normal',1),
('C2-S3-R4-P1',2,3,4,1,'normal',1),
('C2-S3-R4-P2',2,3,4,2,'normal',1),
('C2-S3-R4-P3',2,3,4,3,'normal',1),
('C2-S3-R4-P4',2,3,4,4,'normal',1),
('C2-S3-R4-P5',2,3,4,5,'normal',1),
('C2-S3-R4-P6',2,3,4,6,'normal',1),
('C2-S3-R4-P7',2,3,4,7,'normal',1),
('C2-S3-R4-P8',2,3,4,8,'normal',1),
('C2-S3-R5-P1',2,3,5,1,'wide',2),
('C2-S3-R5-P2',2,3,5,2,'wide',2),
('C2-S3-R5-P3',2,3,5,3,'wide',2),
('C2-S3-R5-P4',2,3,5,4,'wide',2),
('C2-S3-R6-P1',2,3,6,1,'wide',2),
('C2-S3-R6-P2',2,3,6,2,'wide',2),
('C2-S3-R6-P3',2,3,6,3,'wide',2),
('C2-S3-R6-P4',2,3,6,4,'wide',2),
('C2-S3-R7-P1',2,3,7,1,'wide',2),
('C2-S3-R7-P2',2,3,7,2,'wide',2),
('C2-S3-R7-P3',2,3,7,3,'wide',2),
('C2-S3-R7-P4',2,3,7,4,'wide',2),
('C3-S1-R1-P1',3,1,1,1,'normal',1),
('C3-S1-R1-P2',3,1,1,2,'normal',1),
('C3-S1-R1-P3',3,1,1,3,'normal',1),
('C3-S1-R1-P4',3,1,1,4,'normal',1),
('C3-S1-R1-P5',3,1,1,5,'normal',1),
('C3-S1-R1-P6',3,1,1,6,'normal',1),
('C3-S1-R1-P7',3,1,1,7,'normal',1),
('C3-S1-R1-P8',3,1,1,8,'normal',1),
('C3-S1-R2-P1',3,1,2,1,'normal',1),
('C3-S1-R2-P2',3,1,2,2,'normal',1),
('C3-S1-R2-P3',3,1,2,3,'normal',1),
('C3-S1-R2-P4',3,1,2,4,'normal',1),
('C3-S1-R2-P5',3,1,2,5,'normal',1),
('C3-S1-R2-P6',3,1,2,6,'normal',1),
('C3-S1-R2-P7',3,1,2,7,'normal',1),
('C3-S1-R2-P8',3,1,2,8,'normal',1),
('C3-S1-R3-P1',3,1,3,1,'normal',1),
('C3-S1-R3-P2',3,1,3,2,'normal',1),
('C3-S1-R3-P3',3,1,3,3,'normal',1),
('C3-S1-R3-P4',3,1,3,4,'normal',1),
('C3-S1-R3-P5',3,1,3,5,'normal',1),
('C3-S1-R3-P6',3,1,3,6,'normal',1),
('C3-S1-R3-P7',3,1,3,7,'normal',1),
('C3-S1-R3-P8',3,1,3,8,'normal',1),
('C3-S1-R4-P1',3,1,4,1,'normal',1),
('C3-S1-R4-P2',3,1,4,2,'normal',1),
('C3-S1-R4-P3',3,1,4,3,'normal',1),
('C3-S1-R4-P4',3,1,4,4,'normal',1),
('C3-S1-R4-P5',3,1,4,5,'normal',1),
('C3-S1-R4-P6',3,1,4,6,'normal',1),
('C3-S1-R4-P7',3,1,4,7,'normal',1),
('C3-S1-R4-P8',3,1,4,8,'normal',1),
('C3-S1-R5-P1',3,1,5,1,'wide',2),
('C3-S1-R5-P2',3,1,5,2,'wide',2),
('C3-S1-R5-P3',3,1,5,3,'wide',2),
('C3-S1-R5-P4',3,1,5,4,'wide',2),
('C3-S1-R6-P1',3,1,6,1,'wide',2),
('C3-S1-R6-P2',3,1,6,2,'wide',2),
('C3-S1-R6-P3',3,1,6,3,'wide',2),
('C3-S1-R6-P4',3,1,6,4,'wide',2),
('C3-S1-R7-P1',3,1,7,1,'wide',2),
('C3-S1-R7-P2',3,1,7,2,'wide',2),
('C3-S1-R7-P3',3,1,7,3,'wide',2),
('C3-S1-R7-P4',3,1,7,4,'wide',2),
('C3-S2-R1-P1',3,2,1,1,'normal',1),
('C3-S2-R1-P2',3,2,1,2,'normal',1),
('C3-S2-R1-P3',3,2,1,3,'normal',1),
('C3-S2-R1-P4',3,2,1,4,'normal',1),
('C3-S2-R1-P5',3,2,1,5,'normal',1),
('C3-S2-R1-P6',3,2,1,6,'normal',1),
('C3-S2-R1-P7',3,2,1,7,'normal',1),
('C3-S2-R1-P8',3,2,1,8,'normal',1),
('C3-S2-R2-P1',3,2,2,1,'normal',1),
('C3-S2-R2-P2',3,2,2,2,'normal',1),
('C3-S2-R2-P3',3,2,2,3,'normal',1),
('C3-S2-R2-P4',3,2,2,4,'normal',1),
('C3-S2-R2-P5',3,2,2,5,'normal',1),
('C3-S2-R2-P6',3,2,2,6,'normal',1),
('C3-S2-R2-P7',3,2,2,7,'normal',1),
('C3-S2-R2-P8',3,2,2,8,'normal',1),
('C3-S2-R3-P1',3,2,3,1,'normal',1),
('C3-S2-R3-P2',3,2,3,2,'normal',1),
('C3-S2-R3-P3',3,2,3,3,'normal',1),
('C3-S2-R3-P4',3,2,3,4,'normal',1),
('C3-S2-R3-P5',3,2,3,5,'normal',1),
('C3-S2-R3-P6',3,2,3,6,'normal',1),
('C3-S2-R3-P7',3,2,3,7,'normal',1),
('C3-S2-R3-P8',3,2,3,8,'normal',1),
('C3-S2-R4-P1',3,2,4,1,'normal',1),
('C3-S2-R4-P2',3,2,4,2,'normal',1),
('C3-S2-R4-P3',3,2,4,3,'normal',1),
('C3-S2-R4-P4',3,2,4,4,'normal',1),
('C3-S2-R4-P5',3,2,4,5,'normal',1),
('C3-S2-R4-P6',3,2,4,6,'normal',1),
('C3-S2-R4-P7',3,2,4,7,'normal',1),
('C3-S2-R4-P8',3,2,4,8,'normal',1),
('C3-S2-R5-P1',3,2,5,1,'wide',2),
('C3-S2-R5-P2',3,2,5,2,'wide',2),
('C3-S2-R5-P3',3,2,5,3,'wide',2),
('C3-S2-R5-P4',3,2,5,4,'wide',2),
('C3-S2-R6-P1',3,2,6,1,'wide',2),
('C3-S2-R6-P2',3,2,6,2,'wide',2),
('C3-S2-R6-P3',3,2,6,3,'wide',2),
('C3-S2-R6-P4',3,2,6,4,'wide',2),
('C3-S2-R7-P1',3,2,7,1,'wide',2),
('C3-S2-R7-P2',3,2,7,2,'wide',2),
('C3-S2-R7-P3',3,2,7,3,'wide',2),
('C3-S2-R7-P4',3,2,7,4,'wide',2),
('C3-S3-R1-P1',3,3,1,1,'normal',1),
('C3-S3-R1-P2',3,3,1,2,'normal',1),
('C3-S3-R1-P3',3,3,1,3,'normal',1),
('C3-S3-R1-P4',3,3,1,4,'normal',1),
('C3-S3-R1-P5',3,3,1,5,'normal',1),
('C3-S3-R1-P6',3,3,1,6,'normal',1),
('C3-S3-R1-P7',3,3,1,7,'normal',1),
('C3-S3-R1-P8',3,3,1,8,'normal',1),
('C3-S3-R2-P1',3,3,2,1,'normal',1),
('C3-S3-R2-P2',3,3,2,2,'normal',1),
('C3-S3-R2-P3',3,3,2,3,'normal',1),
('C3-S3-R2-P4',3,3,2,4,'normal',1),
('C3-S3-R2-P5',3,3,2,5,'normal',1),
('C3-S3-R2-P6',3,3,2,6,'normal',1),
('C3-S3-R2-P7',3,3,2,7,'normal',1),
('C3-S3-R2-P8',3,3,2,8,'normal',1),
('C3-S3-R3-P1',3,3,3,1,'normal',1),
('C3-S3-R3-P2',3,3,3,2,'normal',1),
('C3-S3-R3-P3',3,3,3,3,'normal',1),
('C3-S3-R3-P4',3,3,3,4,'normal',1),
('C3-S3-R3-P5',3,3,3,5,'normal',1),
('C3-S3-R3-P6',3,3,3,6,'normal',1),
('C3-S3-R3-P7',3,3,3,7,'normal',1),
('C3-S3-R3-P8',3,3,3,8,'normal',1),
('C3-S3-R4-P1',3,3,4,1,'normal',1),
('C3-S3-R4-P2',3,3,4,2,'normal',1),
('C3-S3-R4-P3',3,3,4,3,'normal',1),
('C3-S3-R4-P4',3,3,4,4,'normal',1),
('C3-S3-R4-P5',3,3,4,5,'normal',1),
('C3-S3-R4-P6',3,3,4,6,'normal',1),
('C3-S3-R4-P7',3,3,4,7,'normal',1),
('C3-S3-R4-P8',3,3,4,8,'normal',1),
('C3-S3-R5-P1',3,3,5,1,'normal',1),
('C3-S3-R5-P2',3,3,5,2,'normal',1),
('C3-S3-R5-P3',3,3,5,3,'normal',1),
('C3-S3-R5-P4',3,3,5,4,'normal',1),
('C3-S3-R5-P5',3,3,5,5,'normal',1),
('C3-S3-R5-P6',3,3,5,6,'normal',1),
('C3-S3-R5-P7',3,3,5,7,'normal',1),
('C3-S3-R5-P8',3,3,5,8,'normal',1),
('C3-S3-R6-P1',3,3,6,1,'normal',1),
('C3-S3-R6-P2',3,3,6,2,'normal',1),
('C3-S3-R6-P3',3,3,6,3,'normal',1),
('C3-S3-R6-P4',3,3,6,4,'normal',1),
('C3-S3-R6-P5',3,3,6,5,'normal',1),
('C3-S3-R6-P6',3,3,6,6,'normal',1),
('C3-S3-R6-P7',3,3,6,7,'normal',1),
('C3-S3-R6-P8',3,3,6,8,'normal',1),
('C3-S3-R7-P1',3,3,7,1,'wide',2),
('C3-S3-R7-P2',3,3,7,2,'wide',2),
('C3-S3-R7-P3',3,3,7,3,'wide',2),
('C3-S3-R7-P4',3,3,7,4,'wide',2)
on conflict (id) do nothing;

-- ============================================================================
--  LISTO. Da de alta la sucursal e importa el CSV desde el portal de ADMIN.
--  NOTAS PRODUCCION: 1) password -> Supabase Auth o pgcrypto crypt().
--   2) restringir ventas por auth.uid(). 3) escritura productos/inventario solo admin.
-- ============================================================================

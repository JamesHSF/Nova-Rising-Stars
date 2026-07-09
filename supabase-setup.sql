-- =====================================================================
-- 摘星計畫 Supabase 設定腳本
-- 使用方式：Supabase Dashboard → SQL Editor → 貼上全部 → Run
-- =====================================================================

-- ---------- 資料表 ----------
-- 組長組別（team）：組長帶的分組，組長面板使用
create table if not exists public.teams (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  leader_id uuid references auth.users(id),
  created_at timestamptz default now()
);

-- 業務組別（group）：最高管理員建立、指派業務組別管理員
create table if not exists public.groups (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  admin_id uuid references auth.users(id),    -- 業務組別管理員（唯一能看/匯出該組資料的人）
  created_at timestamptz default now()
);

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  name text not null default '',
  role text not null default 'member' check (role in ('member','leader','admin')),
  is_super boolean not null default false,    -- 最高管理員（可建立業務組別、指派管理員）
  team_id uuid references public.teams(id) on delete set null,   -- 組長組別
  group_id uuid references public.groups(id) on delete set null, -- 業務組別（與組長組別各自獨立）
  created_at timestamptz default now()
);
-- 既有資料庫升級：補上欄位
alter table public.profiles add column if not exists is_super boolean not null default false;
alter table public.profiles add column if not exists team_id uuid references public.teams(id) on delete set null;
alter table public.groups drop column if exists leader_id;

-- 業務組別成員關係（多對多）：一位成員可同時屬於多個業務組別
create table if not exists public.group_members (
  group_id uuid not null references public.groups(id) on delete cascade,
  user_id  uuid not null references auth.users(id) on delete cascade,
  primary key (group_id, user_id)
);
-- 既有資料庫升級：把舊的單一 profiles.group_id 搬進 group_members，再移除該欄位
do $$
begin
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='profiles' and column_name='group_id') then
    insert into public.group_members (group_id, user_id)
      select group_id, id from public.profiles where group_id is not null
      on conflict do nothing;
    alter table public.profiles drop column group_id;
  end if;
end $$;

-- daily/weekly/monthly 三張結構相同：period = 'YYYY-MM-DD' / 'YYYY-Www' / 'YYYY-MM'
create table if not exists public.daily_records (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  period text not null,
  data jsonb not null default '{}',
  updated_at timestamptz default now(),
  unique (user_id, period)
);
create table if not exists public.weekly_records (like public.daily_records including all);
create table if not exists public.monthly_records (like public.daily_records including all);
-- 外鍵：僅在尚未存在時才加，讓整份 SQL 可重複執行
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'weekly_user_fk') then
    alter table public.weekly_records add constraint weekly_user_fk foreign key (user_id) references auth.users(id) on delete cascade;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'monthly_user_fk') then
    alter table public.monthly_records add constraint monthly_user_fk foreign key (user_id) references auth.users(id) on delete cascade;
  end if;
end $$;

create table if not exists public.nudges (
  id uuid primary key default gen_random_uuid(),
  from_name text not null,
  to_id uuid not null references auth.users(id) on delete cascade,
  message text not null default '',
  date text not null,
  created_at timestamptz default now()
);

-- ---------- 註冊時自動建立 profile（第一位註冊者＝最高管理員） ----------
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare first boolean := (select count(*) from public.profiles) = 0;
begin
  insert into public.profiles (id, email, name, role, is_super)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'name', ''),
    case when first then 'admin' else 'member' end,
    first
  );
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- 輔助函式（避免 RLS 遞迴） ----------
create or replace function public.my_role()
returns text language sql security definer stable set search_path = public as
$$ select role from public.profiles where id = auth.uid() $$;

create or replace function public.is_group_admin_of(target_group uuid)
returns boolean language sql security definer stable set search_path = public as
$$ select exists (select 1 from public.groups where id = target_group and admin_id = auth.uid()) $$;

-- 檢視者是否為「目標成員所屬任一業務組別」的管理員（成員可同時屬於多個業務組別）
create or replace function public.is_admin_of_user(target_user uuid)
returns boolean language sql security definer stable set search_path = public as $$
  select exists (
    select 1 from public.group_members gm
    join public.groups g on g.id = gm.group_id
    where gm.user_id = target_user and g.admin_id = auth.uid()
  )
$$;

-- 檢視者是否為「目標成員的守護者組別」的守護者
create or replace function public.is_team_leader_of_user(target_user uuid)
returns boolean language sql security definer stable set search_path = public as $$
  select exists (
    select 1 from public.teams t
    join public.profiles p on p.team_id = t.id
    where p.id = target_user and t.leader_id = auth.uid()
  )
$$;

create or replace function public.team_of(target_user uuid)
returns uuid language sql security definer stable set search_path = public as
$$ select team_id from public.profiles where id = target_user $$;

create or replace function public.am_super()
returns boolean language sql security definer stable set search_path = public as
$$ select coalesce((select is_super from public.profiles where id = auth.uid()), false) $$;

-- 週六～週五週期：回傳該日期所屬週的「週六」日期字串（例：2026-07-04）
create or replace function public.week_key(d date)
returns text language sql immutable as
$$ select to_char(d - ((extract(dow from d)::int + 1) % 7), 'YYYY-MM-DD') $$;

-- 這一天是否為「合格黃星」：業務至少低標 + 專注正向滋養≥1 + 心情日記有填
create or replace function public.day_qualifies(j jsonb)
returns boolean language sql immutable as $$
  select coalesce((j->>'rel')::int, 0) >= 3
     and coalesce((j->>'inv')::int, 0) >= 1
     and coalesce((j->>'list')::int, 0) >= 2
     and jsonb_array_length(coalesce(j->'focus', '[]'::jsonb)) >= 1
     and length(btrim(coalesce(j->>'diary', ''))) > 0
$$;

-- ---------- RLS ----------
alter table public.profiles enable row level security;
alter table public.teams enable row level security;
alter table public.groups enable row level security;
alter table public.daily_records enable row level security;
alter table public.weekly_records enable row level security;
alter table public.monthly_records enable row level security;
alter table public.nudges enable row level security;

-- profiles：自己可讀寫姓名；管理者可讀全部；組長可讀自己「組長組別」的成員
drop policy if exists p_profiles_select on public.profiles;
create policy p_profiles_select on public.profiles for select using (
  id = auth.uid()
  or public.my_role() = 'admin'
  or exists (select 1 from public.teams t where t.leader_id = auth.uid() and t.id = profiles.team_id)
);
drop policy if exists p_profiles_update_self on public.profiles;
create policy p_profiles_update_self on public.profiles for update using (id = auth.uid());
-- 只有最高管理員可調整角色/分組（避免一般管理員互改）
drop policy if exists p_profiles_update_admin on public.profiles;
create policy p_profiles_update_admin on public.profiles for update using (public.am_super());

-- teams（組長組別）：所有登入者可讀；組長可建立自己帶的組；組長/最高管理員可更新
drop policy if exists p_teams_select on public.teams;
create policy p_teams_select on public.teams for select using (auth.uid() is not null);
drop policy if exists p_teams_insert on public.teams;
create policy p_teams_insert on public.teams for insert with check (
  (leader_id = auth.uid() and public.my_role() in ('leader','admin'))
  or public.am_super()   -- 最高管理員可建立守護者組別並指派任一守護者
);
drop policy if exists p_teams_update on public.teams;
create policy p_teams_update on public.teams for update using (leader_id = auth.uid() or public.am_super());

-- groups（業務組別）：所有登入者可讀；僅最高管理員可建立與更新（指派管理員）
drop policy if exists p_groups_select on public.groups;
create policy p_groups_select on public.groups for select using (auth.uid() is not null);
drop policy if exists p_groups_insert on public.groups;
create policy p_groups_insert on public.groups for insert with check (public.am_super());
drop policy if exists p_groups_update_admin on public.groups;
create policy p_groups_update_admin on public.groups for update using (public.am_super());

-- 三張紀錄表：本人完全控制；「業務組別管理員」或最高管理員可讀該組成員資料
do $$
declare t text;
begin
  foreach t in array array['daily_records','weekly_records','monthly_records'] loop
    execute format('drop policy if exists p_%s_own on public.%s', t, t);
    execute format('create policy p_%s_own on public.%s for all using (user_id = auth.uid()) with check (user_id = auth.uid())', t, t);
    execute format('drop policy if exists p_%s_gadmin on public.%s', t, t);
    execute format('create policy p_%s_gadmin on public.%s for select using (public.is_admin_of_user(user_id) or public.am_super())', t, t);
  end loop;
  -- 守護者可讀自己組員的「每日／每週」詳細資料（不含每月）
  foreach t in array array['daily_records','weekly_records'] loop
    execute format('drop policy if exists p_%s_tleader on public.%s', t, t);
    execute format('create policy p_%s_tleader on public.%s for select using (public.is_team_leader_of_user(user_id))', t, t);
  end loop;
end $$;

-- nudges：收件人可讀/刪自己的；組長（自己組長組別）或業務組別管理員可寄給該成員
drop policy if exists p_nudges_select on public.nudges;
create policy p_nudges_select on public.nudges for select using (to_id = auth.uid());
drop policy if exists p_nudges_delete on public.nudges;
create policy p_nudges_delete on public.nudges for delete using (to_id = auth.uid());
drop policy if exists p_nudges_insert on public.nudges;
create policy p_nudges_insert on public.nudges for insert with check (
  exists (select 1 from public.teams t where t.id = public.team_of(to_id) and t.leader_id = auth.uid())
  or public.is_admin_of_user(to_id)
);

-- group_members（業務組別成員）：所有登入者可讀；僅最高管理員可增刪
alter table public.group_members enable row level security;
drop policy if exists p_gm_select on public.group_members;
create policy p_gm_select on public.group_members for select using (auth.uid() is not null);
drop policy if exists p_gm_write on public.group_members;
create policy p_gm_write on public.group_members for all using (public.am_super()) with check (public.am_super());

-- ---------- 組長達成率 RPC：以「組長組別（team）」成員為對象（security definer：只回勾勾） ----------
-- 每週盤點週期為「週六～週五」，且盤點的是已結束的上一週
create or replace function public.team_completion()
returns table (id uuid, name text, role text, daily boolean, weekly boolean, monthly boolean, rate7 int)
language plpgsql security definer set search_path = public as $$
declare
  tid uuid;
  today text := to_char(now(), 'YYYY-MM-DD');
  reviewwk text := public.week_key((now() - interval '7 days')::date); -- 上一個週六～週五
  thismonth text := to_char(now(), 'YYYY-MM');
begin
  select t.id into tid from public.teams t
  where t.leader_id = auth.uid()
     or t.id = (select team_id from public.profiles where profiles.id = auth.uid());
  if tid is null then return; end if;

  return query
  select p.id, p.name, p.role,
    exists (select 1 from public.daily_records d where d.user_id = p.id and d.period = today),
    exists (select 1 from public.weekly_records w where w.user_id = p.id and w.period = reviewwk),
    exists (select 1 from public.monthly_records m where m.user_id = p.id and m.period = thismonth),
    (select count(distinct d.period)::int * 100 / 7 from public.daily_records d
      where d.user_id = p.id and d.period >= to_char(now() - interval '6 days', 'YYYY-MM-DD'))
  from public.profiles p
  where p.team_id = tid;
end $$;

grant execute on function public.team_completion() to authenticated;

-- ---------- 組長每週星星軌跡 RPC：以組長組別成員為對象（只回傳達成數，不含內容） ----------
create or replace function public.team_star_trails()
returns table (member_id uuid, name text, week text, yellow int, is_super boolean)
language plpgsql security definer set search_path = public as $$
declare tid uuid;
begin
  select t.id into tid from public.teams t
  where t.leader_id = auth.uid()
     or t.id = (select team_id from public.profiles where profiles.id = auth.uid())
  limit 1;
  if tid is null then return; end if;

  return query
  with mem as (
    select pr.id, pr.name from public.profiles pr where pr.team_id = tid
  ),
  yc as (
    select d.user_id, public.week_key(d.period::date) wk, count(*)::int yellow
    from public.daily_records d join mem on mem.id = d.user_id
    where public.day_qualifies(d.data)
    group by d.user_id, public.week_key(d.period::date)
  ),
  sc as (
    select w.user_id, w.period wk
    from public.weekly_records w join mem on mem.id = w.user_id
    where coalesce((w.data->>'super_star')::boolean, false)
  ),
  merged as (
    select user_id, wk, yellow, false sup from yc
    union all
    select user_id, wk, 0, true from sc
  )
  select mem.id, mem.name, merged.wk, max(merged.yellow)::int, bool_or(merged.sup)
  from merged join mem on mem.id = merged.user_id
  group by mem.id, mem.name, merged.wk;
end $$;

grant execute on function public.team_star_trails() to authenticated;

-- ---------- 團隊橘星/彩虹星 RPC：全員當日皆黃星→橘星；全員該週皆紫星→彩虹星 ----------
create or replace function public.team_bonus_stars()
returns table (kind text, key text)
language plpgsql security definer set search_path = public as $$
declare tid uuid; n int;
begin
  select t.id into tid from public.teams t
  where t.leader_id = auth.uid()
     or t.id = (select team_id from public.profiles where profiles.id = auth.uid())
  limit 1;
  if tid is null then return; end if;
  select count(*) into n from public.profiles where team_id = tid;
  if n = 0 then return; end if;

  return query
  -- 橘星：某天全員皆有合格打卡
  select 'orange'::text, d.period
  from public.daily_records d join public.profiles p on p.id = d.user_id
  where p.team_id = tid and public.day_qualifies(d.data)
  group by d.period having count(distinct d.user_id) = n
  union all
  -- 彩虹星：某週全員皆達成紫星
  select 'rainbow'::text, w.period
  from public.weekly_records w join public.profiles p on p.id = w.user_id
  where p.team_id = tid and coalesce((w.data->>'super_star')::boolean, false)
  group by w.period having count(distinct w.user_id) = n;
end $$;

grant execute on function public.team_bonus_stars() to authenticated;

-- ---------- 最高管理員統計：可讀全部紀錄（供統計報表用） ----------
-- 三張紀錄表已在上方加入「public.am_super()」可 SELECT 的政策；profiles 由 my_role()='admin' 可讀全部。
-- 因此最高管理員在前端即可彙整所有統計（黃/紫/橘/彩虹星、BV/IBV、簽約店長等），不需額外 RPC。

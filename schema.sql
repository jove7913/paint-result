-- ═══════════════════════════════════════════════════════════
-- 도장 실적 앱 · paint 스키마
-- 기존 Supabase 프로젝트 안에서 논리적으로 분리해 사용한다.
-- SQL Editor 에 통째로 붙여넣고 실행.
-- ═══════════════════════════════════════════════════════════

create schema if not exists paint;

-- ── 작업자 ────────────────────────────────────────────────
-- auth.users 와 1:1. 회원가입 시 트리거로 자동 생성되고,
-- approved = false 상태에서는 아무것도 못 한다.
create table if not exists paint.workers (
  id          uuid primary key references auth.users(id) on delete cascade,
  emp_no      text unique not null,
  name        text not null,
  role        text not null default 'worker' check (role in ('worker','admin')),
  approved    boolean not null default false,
  created_at  timestamptz not null default now()
);

-- ── 품번 마스터 ───────────────────────────────────────────
-- 품번 / 품명 / 컬러 / 도장사양 네 가지만 관리한다. 품명은 영문 하나.
create table if not exists paint.parts (
  part_no   text primary key,
  name      text,                                  -- 품명 (영문)
  color     text check (color in ('BK','SL','GY','WH')),
  spec      text,                                  -- 도장사양
  active    boolean not null default true
);

-- 이전 버전(품명 2칸)으로 이미 만들었다면 아래가 자동으로 합쳐준다
do $$
begin
  if exists (select 1 from information_schema.columns
             where table_schema='paint' and table_name='parts' and column_name='name_kr') then
    alter table paint.parts add column if not exists name text;
    update paint.parts set name = coalesce(nullif(name_es,''), nullif(name_kr,''), part_no) where name is null;
    alter table paint.parts drop column if exists name_kr;
    alter table paint.parts drop column if exists name_es;
  end if;
end $$;

-- ── 계획 ─────────────────────────────────────────────────
-- seq = 라인별 표시 순서. 작업자 화면은 이 순서 그대로 보여준다.
create table if not exists paint.plans (
  id          uuid primary key default gen_random_uuid(),
  work_date   date not null default current_date,
  line_id     text not null check (line_id in ('1','2','3','4','5')),
  shift       text not null check (shift in ('A','B')),
  part_no     text not null references paint.parts(part_no),
  plan_qty    int  not null default 0 check (plan_qty >= 0),
  seq         int  not null default 0,
  is_adhoc    boolean not null default false,   -- 계획에 없던 품번
  status      text not null default 'open' check (status in ('open','closed')),
  created_by  uuid references paint.workers(id),
  created_at  timestamptz not null default now()
);
create index if not exists plans_day_line on paint.plans (work_date, line_id, seq);

-- ── 실적 ─────────────────────────────────────────────────
-- 계획 1건당 실적 1행.
-- 작업자가 계획 카드의 [투입시작] 을 누르는 순간 started_at 만 담긴 행이 생긴다.
-- 이후 품번을 눌러 들어가 투입수량 / OK / NG 를 채운다.
-- 직행율(FTT)은 ok/input 으로 자동 계산되는 컬럼이라 입력받지 않는다.
create table if not exists paint.results (
  id          uuid primary key default gen_random_uuid(),
  plan_id     uuid not null unique references paint.plans(id) on delete cascade,
  started_at  time not null,                        -- 투입시작
  input_qty   int  not null default 0 check (input_qty >= 0),
  ok_qty      int  not null default 0 check (ok_qty    >= 0),
  ng_qty      int  not null default 0 check (ng_qty    >= 0),
  ftt_pct     numeric(5,2) generated always as
                (case when input_qty > 0 then round(ok_qty::numeric / input_qty * 100, 2) end) stored,
  comment     text,
  input_by    uuid references paint.workers(id),
  input_at    timestamptz not null default now(),
  result_by   uuid references paint.workers(id),
  result_at   timestamptz,
  updated_at  timestamptz not null default now(),
  constraint qty_balance check (ok_qty + ng_qty <= input_qty)
);
create index if not exists results_plan on paint.results (plan_id);

-- ── 수정 이력 ─────────────────────────────────────────────
-- 투입 입력자와 결과 입력자가 다를 수 있으므로 변경 흔적을 남긴다.
create table if not exists paint.result_edits (
  id         bigserial primary key,
  result_id  uuid not null references paint.results(id) on delete cascade,
  editor     uuid references paint.workers(id),
  before     jsonb,
  after      jsonb,
  edited_at  timestamptz not null default now()
);

-- ═══ 트리거 ═══════════════════════════════════════════════

-- 수정 시 updated_at 갱신 + 이력 기록
create or replace function paint.log_edit() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  if new.ok_qty + new.ng_qty > 0 and old.ok_qty + old.ng_qty = 0 then
    new.result_by := auth.uid();
    new.result_at := now();
  end if;
  insert into paint.result_edits (result_id, editor, before, after)
  values (old.id, auth.uid(),
    jsonb_build_object('in',old.input_qty,'ok',old.ok_qty,'ng',old.ng_qty,'cm',old.comment),
    jsonb_build_object('in',new.input_qty,'ok',new.ok_qty,'ng',new.ng_qty,'cm',new.comment));
  return new;
end $$;
drop trigger if exists trg_log_edit on paint.results;
create trigger trg_log_edit before update on paint.results
  for each row execute function paint.log_edit();

-- 회원가입 시 workers 행 자동 생성 (미승인 상태)
create or replace function paint.on_signup() returns trigger
language plpgsql security definer set search_path = paint, public as $$
begin
  insert into paint.workers (id, emp_no, name)
  values (new.id,
          coalesce(new.raw_user_meta_data->>'emp_no', new.id::text),
          coalesce(new.raw_user_meta_data->>'name', '이름 미등록'))
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists trg_on_signup on auth.users;
create trigger trg_on_signup after insert on auth.users
  for each row execute function paint.on_signup();

-- ═══ RLS ══════════════════════════════════════════════════
-- 정책 안에서 workers 를 직접 조회하면 무한 재귀가 난다.
-- security definer 함수로 감싸서 우회한다.

create or replace function paint.is_approved() returns boolean
language sql stable security definer set search_path = paint as $$
  select coalesce((select approved from paint.workers where id = auth.uid()), false)
$$;

create or replace function paint.is_admin() returns boolean
language sql stable security definer set search_path = paint as $$
  select coalesce((select approved and role = 'admin' from paint.workers where id = auth.uid()), false)
$$;

alter table paint.workers      enable row level security;
alter table paint.parts        enable row level security;
alter table paint.plans        enable row level security;
alter table paint.results      enable row level security;
alter table paint.result_edits enable row level security;

-- 여러 번 실행해도 되도록 기존 정책을 먼저 지운다
drop policy if exists w_read   on paint.workers;
drop policy if exists w_delete on paint.workers;
drop policy if exists w_admin  on paint.workers;
drop policy if exists p_read   on paint.parts;
drop policy if exists p_write  on paint.parts;
drop policy if exists pl_read  on paint.plans;
drop policy if exists pl_admin on paint.plans;
drop policy if exists pl_adhoc on paint.plans;
drop policy if exists r_read   on paint.results;
drop policy if exists r_insert on paint.results;
drop policy if exists r_update on paint.results;
drop policy if exists r_delete on paint.results;
drop policy if exists re_read  on paint.result_edits;

-- workers: 승인된 사용자는 이름 조회 가능(실적 이력 표시용),
--          승인·권한 변경은 관리자만
create policy w_read  on paint.workers for select
  using (id = auth.uid() or paint.is_approved());
create policy w_admin on paint.workers for update
  using (paint.is_admin()) with check (paint.is_admin());
-- 작업자 삭제는 관리자만 (로그인 계정 자체는 대시보드 Authentication → Users 에서 삭제)
create policy w_delete on paint.workers for delete using (paint.is_admin());

-- parts / plans: 승인된 사용자는 읽기, 등록·수정은 관리자만
create policy p_read  on paint.parts for select using (paint.is_approved());
create policy p_write on paint.parts for all    using (paint.is_admin()) with check (paint.is_admin());

create policy pl_read  on paint.plans for select using (paint.is_approved());
create policy pl_admin on paint.plans for all    using (paint.is_admin()) with check (paint.is_admin());
-- 계획에 없는 품번은 작업자도 직접 만들 수 있게 허용
create policy pl_adhoc on paint.plans for insert
  with check (paint.is_approved() and is_adhoc = true);

-- results: 승인된 사용자는 조회·입력·수정, 삭제는 관리자만
create policy r_read   on paint.results for select using (paint.is_approved());
create policy r_insert on paint.results for insert with check (paint.is_approved() and input_by = auth.uid());
create policy r_update on paint.results for update using (paint.is_approved()) with check (paint.is_approved());
create policy r_delete on paint.results for delete using (paint.is_admin());

create policy re_read on paint.result_edits for select using (paint.is_approved());

-- ═══ 참조 정리 ════════════════════════════════════════════
-- 작업자를 삭제해도 실적·계획 데이터는 남고 이름만 비워지도록 한다
do $$
begin
  alter table paint.results      drop constraint if exists results_input_by_fkey;
  alter table paint.results      drop constraint if exists results_result_by_fkey;
  alter table paint.plans        drop constraint if exists plans_created_by_fkey;
  alter table paint.result_edits drop constraint if exists result_edits_editor_fkey;

  alter table paint.results add constraint results_input_by_fkey
    foreign key (input_by)  references paint.workers(id) on delete set null;
  alter table paint.results add constraint results_result_by_fkey
    foreign key (result_by) references paint.workers(id) on delete set null;
  alter table paint.plans add constraint plans_created_by_fkey
    foreign key (created_by) references paint.workers(id) on delete set null;
  alter table paint.result_edits add constraint result_edits_editor_fkey
    foreign key (editor) references paint.workers(id) on delete set null;
end $$;

-- ═══ 권한 (PostgREST 노출) ════════════════════════════════
-- public 이 아닌 스키마는 아래 grant 가 없으면 API 에서 보이지 않는다.
grant usage on schema paint to anon, authenticated;
grant all on all tables    in schema paint to anon, authenticated;
grant all on all sequences in schema paint to anon, authenticated;
alter default privileges in schema paint grant all on tables    to anon, authenticated;
alter default privileges in schema paint grant all on sequences to anon, authenticated;

-- ═══ Realtime ═════════════════════════════════════════════
-- 이미 추가돼 있으면 넘어간다
do $$
begin
  begin alter publication supabase_realtime add table paint.results; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table paint.plans;   exception when duplicate_object then null; end;
end $$;

-- ═══ 진척 뷰 ══════════════════════════════════════════════
-- status: 실적 행이 없으면 wait(대기), 있으면 run(투입중),
--         OK/NG 가 입력되면 done(생산종료)
create or replace view paint.v_progress as
select p.id, p.work_date, p.line_id, p.shift, p.seq, p.part_no, p.plan_qty, p.is_adhoc,
       pt.name, pt.color, pt.spec,
       r.started_at, r.input_qty, r.ok_qty, r.ng_qty, r.ftt_pct, r.comment,
       round(coalesce(r.ok_qty,0)::numeric / nullif(p.plan_qty,0) * 100, 1) as achieve_pct,
       case when r.id is null then 'wait'
            when r.ok_qty + r.ng_qty > 0 then 'done'
            else 'run' end as status
from paint.plans p
join paint.parts pt on pt.part_no = p.part_no
left join paint.results r on r.plan_id = p.id;

-- ═══ 초기 데이터 ══════════════════════════════════════════
insert into paint.parts (part_no, name, color, spec) values
 ('A-1023','Door clip','BK','1C1B mate'),
 ('A-2210','Cover bracket','SL','2C1B metallic'),
 ('B-1140','Hinge cap','BK','1C1B mate'),
 ('B-3302','Nozzle ring','GY','2C1B semi-gloss')
on conflict do nothing;

-- 최초 관리자 지정: 본인 계정으로 가입한 뒤 아래 실행
-- update paint.workers set approved = true, role = 'admin' where emp_no = '본인사번';

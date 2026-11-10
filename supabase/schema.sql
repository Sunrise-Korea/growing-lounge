-- =========================================================
-- 그로잉라운지 Supabase 스키마
-- Supabase 대시보드 → SQL Editor → New query 에 전체를 붙여넣고 Run.
-- 여러 번 실행해도 안전하도록 작성했어요 (있으면 건너뜀).
-- =========================================================

-- ---------- 1. 메뉴 ----------
create table if not exists public.menu_items (
  id          bigint generated always as identity primary key,
  category    text   not null check (category in ('coffee','drink','tea')),
  name        text   not null,
  price       integer not null check (price >= 0),
  sort_order  integer not null default 0,
  is_available boolean not null default true,
  created_at  timestamptz not null default now()
);

-- ---------- 2. 영업시간 (0=일 ~ 6=토) ----------
create table if not exists public.business_hours (
  dow         smallint primary key check (dow between 0 and 6),
  is_closed   boolean not null default false,
  open_time   time,
  close_time  time,
  last_order  time
);

-- ---------- 3. 룸 ----------
create table if not exists public.rooms (
  id          text primary key,
  name        text not null,
  min_people  integer not null,
  max_people  integer not null,
  description text,
  price_per_person_hour integer not null default 2000,
  sort_order  integer not null default 0
);

-- ---------- 4. 룸 예약 신청 ----------
create table if not exists public.room_bookings (
  id          bigint generated always as identity primary key,
  room_id     text not null references public.rooms(id),
  booking_date date not null,
  start_time  time not null,
  hours       numeric(3,1) not null check (hours between 1 and 12),
  people      integer not null check (people between 1 and 40),
  name        text not null check (char_length(name) between 1 and 30),
  phone       text not null check (phone ~ '^[0-9-]{9,14}$'),
  memo        text check (char_length(memo) <= 300),
  status      text not null default 'pending' check (status in ('pending','confirmed','cancelled')),
  created_at  timestamptz not null default now()
);

-- ---------- 5. 방명록 ----------
create table if not exists public.guestbook (
  id          bigint generated always as identity primary key,
  nickname    text not null check (char_length(nickname) between 1 and 20),
  message     text not null check (char_length(message) between 1 and 300),
  rating      smallint check (rating between 1 and 5),
  is_hidden   boolean not null default false,
  created_at  timestamptz not null default now()
);

-- ---------- 6. 클래스 ----------
create table if not exists public.classes (
  id          bigint generated always as identity primary key,
  title       text not null,
  description text,
  class_date  date not null,
  start_time  time not null,
  duration_min integer not null default 120,
  price       integer not null default 0,
  capacity    integer not null check (capacity > 0),
  is_open     boolean not null default true,
  created_at  timestamptz not null default now()
);

create table if not exists public.class_signups (
  id          bigint generated always as identity primary key,
  class_id    bigint not null references public.classes(id) on delete cascade,
  name        text not null check (char_length(name) between 1 and 30),
  phone       text not null check (phone ~ '^[0-9-]{9,14}$'),
  people      integer not null default 1 check (people between 1 and 6),
  memo        text check (char_length(memo) <= 300),
  status      text not null default 'pending' check (status in ('pending','confirmed','cancelled')),
  created_at  timestamptz not null default now()
);

-- =========================================================
-- 보안(RLS): 방문자(anon)가 할 수 있는 일만 허용
--  - 메뉴/영업시간/룸/클래스/방명록: 읽기
--  - 예약/방명록/클래스 신청: 쓰기만 (다른 사람 연락처는 못 봄)
--  - 수정/삭제는 대시보드(관리자)에서만
-- =========================================================
alter table public.menu_items     enable row level security;
alter table public.business_hours enable row level security;
alter table public.rooms          enable row level security;
alter table public.room_bookings  enable row level security;
alter table public.guestbook      enable row level security;
alter table public.classes        enable row level security;
alter table public.class_signups  enable row level security;

drop policy if exists "public read menu"   on public.menu_items;
create policy "public read menu"   on public.menu_items     for select to anon, authenticated using (is_available);
drop policy if exists "public read hours"  on public.business_hours;
create policy "public read hours"  on public.business_hours for select to anon, authenticated using (true);
drop policy if exists "public read rooms"  on public.rooms;
create policy "public read rooms"  on public.rooms          for select to anon, authenticated using (true);
drop policy if exists "public read classes" on public.classes;
create policy "public read classes" on public.classes       for select to anon, authenticated using (is_open);

drop policy if exists "public read guestbook"  on public.guestbook;
create policy "public read guestbook"  on public.guestbook for select to anon, authenticated using (not is_hidden);
drop policy if exists "public write guestbook" on public.guestbook;
create policy "public write guestbook" on public.guestbook for insert to anon, authenticated
  with check (is_hidden = false);

drop policy if exists "public create booking" on public.room_bookings;
create policy "public create booking" on public.room_bookings for insert to anon, authenticated
  with check (status = 'pending' and booking_date >= (now() at time zone 'Asia/Seoul')::date);

drop policy if exists "public create signup" on public.class_signups;
create policy "public create signup" on public.class_signups for insert to anon, authenticated
  with check (status = 'pending');

-- 테이블 권한 (RLS가 실제 범위를 제한)
grant select on public.menu_items, public.business_hours, public.rooms, public.classes, public.guestbook to anon, authenticated;
grant insert on public.guestbook, public.room_bookings, public.class_signups to anon, authenticated;

-- =========================================================
-- 공개용 함수: 개인정보 없이 필요한 정보만 돌려줌
-- =========================================================

-- 특정 날짜에 이미 잡힌 룸 시간대 (이름/연락처 없음)
create or replace function public.room_busy_slots(p_date date)
returns table (room_id text, start_time time, end_time time)
language sql stable security definer set search_path = public as $$
  select b.room_id, b.start_time, (b.start_time + make_interval(mins => (b.hours * 60)::int))::time
  from room_bookings b
  where b.booking_date = p_date and b.status <> 'cancelled'
  order by 1, 2;
$$;

-- 클래스 목록 + 남은 자리
create or replace function public.class_list()
returns table (id bigint, title text, description text, class_date date, start_time time,
               duration_min integer, price integer, capacity integer, seats_left integer)
language sql stable security definer set search_path = public as $$
  select c.id, c.title, c.description, c.class_date, c.start_time, c.duration_min, c.price, c.capacity,
         greatest(c.capacity - coalesce(sum(s.people) filter (where s.status <> 'cancelled'), 0), 0)::int
  from classes c
  left join class_signups s on s.class_id = c.id
  where c.is_open and c.class_date >= (now() at time zone 'Asia/Seoul')::date
  group by c.id
  order by c.class_date, c.start_time;
$$;

grant execute on function public.room_busy_slots(date) to anon, authenticated;
grant execute on function public.class_list() to anon, authenticated;

-- 예약 검증: 휴무일·영업시간·인원·시간 겹침
create or replace function public.check_room_booking()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  h business_hours%rowtype;
  r rooms%rowtype;
  new_end time := (new.start_time + make_interval(mins => (new.hours * 60)::int))::time;
begin
  select * into r from rooms where id = new.room_id;
  if new.people < r.min_people or new.people > r.max_people then
    raise exception '이 룸은 %~%명까지 이용할 수 있어요.', r.min_people, r.max_people;
  end if;

  select * into h from business_hours where dow = extract(dow from new.booking_date);
  if h.is_closed then
    raise exception '선택한 날은 정기 휴무일이에요.';
  end if;
  if new.start_time < h.open_time or new_end > h.close_time or new_end <= new.start_time then
    raise exception '영업시간(% ~ %) 안에서만 예약할 수 있어요.', to_char(h.open_time,'HH24:MI'), to_char(h.close_time,'HH24:MI');
  end if;

  if exists (
    select 1 from room_bookings b
    where b.room_id = new.room_id and b.booking_date = new.booking_date and b.status <> 'cancelled'
      and b.id is distinct from new.id
      and b.start_time < new_end
      and (b.start_time + make_interval(mins => (b.hours * 60)::int))::time > new.start_time
  ) then
    raise exception '이미 예약된 시간과 겹쳐요. 다른 시간을 골라 주세요.';
  end if;
  return new;
end $$;

drop trigger if exists trg_check_room_booking on public.room_bookings;
create trigger trg_check_room_booking before insert on public.room_bookings
  for each row execute function public.check_room_booking();

-- 클래스 정원 검증
create or replace function public.check_class_signup()
returns trigger language plpgsql security definer set search_path = public as $$
declare left_seats int;
begin
  perform 1 from classes where id = new.class_id for update;
  select seats_left into left_seats from class_list() where id = new.class_id;
  if left_seats is null then
    raise exception '신청할 수 없는 클래스예요.';
  end if;
  if new.people > left_seats then
    raise exception '남은 자리가 %명이에요.', left_seats;
  end if;
  return new;
end $$;

drop trigger if exists trg_check_class_signup on public.class_signups;
create trigger trg_check_class_signup before insert on public.class_signups
  for each row execute function public.check_class_signup();

-- =========================================================
-- 초기 데이터 (비어 있을 때만 넣음)
-- =========================================================
insert into public.business_hours (dow, is_closed, open_time, close_time, last_order) values
  (0, false, '11:30', '21:30', '21:10'),
  (1, true,  null,    null,    null),
  (2, false, '12:00', '21:30', '21:10'),
  (3, false, '12:00', '21:30', '21:10'),
  (4, false, '12:00', '21:30', '21:10'),
  (5, false, '11:30', '21:30', '21:10'),
  (6, false, '11:30', '21:30', '21:10')
on conflict (dow) do nothing;

insert into public.rooms (id, name, min_people, max_people, description, sort_order) values
  ('seminar', '10인 세미나실',   4, 12, '모니터·프로젝터·화이트보드', 1),
  ('meeting', '회의실',          2,  5, '독립 룸',                   2),
  ('group',   '소모임 룸',       3,  6, '화이트보드·모니터',         3),
  ('work',    '워크·스터디 룸',  2,  4, '2~4인용',                   4),
  ('study',   '1~2인 스터디 룸', 1,  2, '1인 책상 2개',              5)
on conflict (id) do nothing;

insert into public.menu_items (category, name, price, sort_order)
select * from (values
  ('coffee','아메리카노',4000,1), ('coffee','카페라떼',5000,2), ('coffee','바닐라라떼',5500,3),
  ('coffee','카라멜마끼아또',5500,4), ('coffee','헤이즐넛라떼',5500,5), ('coffee','코코넛라떼',5500,6),
  ('coffee','카페모카',5500,7), ('coffee','초코라떼',5500,8),
  ('drink','요거트 스무디',6000,1), ('drink','딸기 스무디',6000,2), ('drink','망고 스무디',6000,3),
  ('drink','블루베리 스무디',6000,4), ('drink','레몬에이드',6000,5), ('drink','자몽에이드',6000,6),
  ('drink','블루베리에이드',6000,7), ('drink','밀크티',6000,8),
  ('tea','얼그레이',4500,1), ('tea','페퍼민트',4500,2), ('tea','자스민 플라워',4500,3),
  ('tea','히비스커스',4500,4), ('tea','크로플',4500,5)
) v(category,name,price,sort_order)
where not exists (select 1 from public.menu_items);

-- 예시 클래스 (날짜는 실제 일정으로 바꿔 주세요)
insert into public.classes (title, description, class_date, start_time, duration_min, price, capacity)
select * from (values
  ('마음 드로잉 원데이 클래스', '그림을 처음 그려도 괜찮아요. 재료는 모두 준비되어 있어요.',
   ((now() at time zone 'Asia/Seoul')::date + 10), time '14:00', 120, 30000, 8),
  ('아이와 함께 그리는 수채화', '7세 이상 아이와 보호자가 함께하는 클래스예요.',
   ((now() at time zone 'Asia/Seoul')::date + 12), time '11:30', 90, 25000, 6)
) v(title,description,class_date,start_time,duration_min,price,capacity)
where not exists (select 1 from public.classes);

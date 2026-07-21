-- Public aggregate metrics from a HealthKit workout recorded by the session
-- author's Apple Watch. Raw heart-rate samples never leave HealthKit.
alter table public.sessions
  add column if not exists average_heart_rate_bpm smallint,
  add column if not exists maximum_heart_rate_bpm smallint,
  add column if not exists active_calories_kcal integer;

alter table public.sessions
  drop constraint if exists sessions_average_heart_rate_range,
  add constraint sessions_average_heart_rate_range
    check (average_heart_rate_bpm is null or average_heart_rate_bpm between 20 and 260),
  drop constraint if exists sessions_maximum_heart_rate_range,
  add constraint sessions_maximum_heart_rate_range
    check (maximum_heart_rate_bpm is null or maximum_heart_rate_bpm between 20 and 260),
  drop constraint if exists sessions_heart_rate_order,
  add constraint sessions_heart_rate_order
    check (
      average_heart_rate_bpm is null
      or maximum_heart_rate_bpm is null
      or maximum_heart_rate_bpm >= average_heart_rate_bpm
    ),
  drop constraint if exists sessions_active_calories_nonnegative,
  add constraint sessions_active_calories_nonnegative
    check (active_calories_kcal is null or active_calories_kcal >= 0);

grant insert (average_heart_rate_bpm, maximum_heart_rate_bpm, active_calories_kcal)
  on public.sessions to authenticated;
grant update (average_heart_rate_bpm, maximum_heart_rate_bpm, active_calories_kcal)
  on public.sessions to authenticated;

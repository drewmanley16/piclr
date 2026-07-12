alter table public.profiles
  add column if not exists height_inches numeric,
  add column if not exists weight_pounds numeric,
  add column if not exists shoe_size numeric;

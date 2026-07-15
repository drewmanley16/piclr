-- Device tokens + push dispatch for APNs.
-- Each row is one APNs device token owned by a user. When a notification is
-- inserted, a trigger asks the `send-push` edge function to deliver it.

create table if not exists public.device_tokens (
    token       text primary key,
    user_id     uuid not null references auth.users(id) on delete cascade,
    platform    text not null default 'ios',
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now()
);

create index if not exists device_tokens_user_id_idx on public.device_tokens(user_id);

alter table public.device_tokens enable row level security;

-- Users can read and delete their own tokens directly.
drop policy if exists "device_tokens_select_own" on public.device_tokens;
create policy "device_tokens_select_own" on public.device_tokens
    for select using (auth.uid() = user_id);

drop policy if exists "device_tokens_delete_own" on public.device_tokens;
create policy "device_tokens_delete_own" on public.device_tokens
    for delete using (auth.uid() = user_id);

grant select, delete on public.device_tokens to authenticated;

-- Upsert helper. SECURITY DEFINER so a device that changes accounts can claim a
-- token that currently belongs to the previous user, which a plain RLS upsert
-- (checking the existing row's owner) could not do.
create or replace function public.register_device_token(p_token text, p_platform text default 'ios')
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
    if auth.uid() is null then
        raise exception 'not authenticated';
    end if;
    insert into public.device_tokens (token, user_id, platform, updated_at)
    values (p_token, auth.uid(), coalesce(p_platform, 'ios'), now())
    on conflict (token) do update
        set user_id = auth.uid(),
            platform = excluded.platform,
            updated_at = now();
end;
$$;

revoke all on function public.register_device_token(text, text) from public;
grant execute on function public.register_device_token(text, text) to authenticated;

-- Fire the edge function when a notification is created. Uses pg_net for an
-- async HTTP call so the inserting transaction never blocks on delivery.
create extension if not exists pg_net with schema extensions;

create or replace function public.dispatch_push_notification()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
declare
    fn_url text;
    fn_key text;
begin
    -- Read the endpoint + shared secret from Supabase Vault. The API SQL role
    -- can't set custom database GUCs, so Vault is the supported store here.
    select decrypted_secret into fn_url from vault.decrypted_secrets where name = 'push_function_url';
    select decrypted_secret into fn_key from vault.decrypted_secrets where name = 'push_function_key';

    -- No-op until the project is configured with the function URL + key.
    if fn_url is null or fn_url = '' then
        return new;
    end if;

    perform net.http_post(
        url     := fn_url,
        headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'Authorization', 'Bearer ' || coalesce(fn_key, '')
        ),
        body    := jsonb_build_object('notification_id', new.id)
    );
    return new;
end;
$$;

drop trigger if exists on_notification_dispatch_push on public.notifications;
create trigger on_notification_dispatch_push
    after insert on public.notifications
    for each row
    execute function public.dispatch_push_notification();

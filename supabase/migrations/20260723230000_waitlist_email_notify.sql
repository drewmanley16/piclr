-- Email notification on waitlist signup.
-- The `public.waitlist` table (id, email, created_at) was created in the
-- dashboard before migrations tracked it; declared here idempotently so the
-- schema is reproducible. When a row is inserted, a trigger asks the
-- `waitlist-notify` edge function to send an email (mirrors the send-push flow).

create table if not exists public.waitlist (
    id          uuid primary key default gen_random_uuid(),
    email       text not null,
    created_at  timestamptz not null default now()
);

-- Fire the edge function when a signup is created. Uses pg_net for an async
-- HTTP call so the inserting transaction never blocks on email delivery.
create extension if not exists pg_net with schema extensions;

create or replace function public.dispatch_waitlist_notify()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
declare
    fn_url text;
    fn_key text;
begin
    -- Endpoint + shared secret live in Supabase Vault. The API SQL role can't
    -- set custom database GUCs, so Vault is the supported store here.
    select decrypted_secret into fn_url from vault.decrypted_secrets where name = 'waitlist_function_url';
    select decrypted_secret into fn_key from vault.decrypted_secrets where name = 'waitlist_function_key';

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
        body    := jsonb_build_object('waitlist_id', new.id)
    );
    return new;
end;
$$;

drop trigger if exists on_waitlist_insert_notify on public.waitlist;
create trigger on_waitlist_insert_notify
    after insert on public.waitlist
    for each row
    execute function public.dispatch_waitlist_notify();

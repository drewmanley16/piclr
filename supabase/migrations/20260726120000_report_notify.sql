-- Email notification when a UGC report is filed.
-- The `reports` table (added in 20260714043658_user_control_and_safety.sql)
-- previously had no consumer — reports landed in the table but nothing acted
-- on them. Apple's Guideline 1.2 requires the developer be able to act on
-- objectionable-content reports, so a report insert now fires the
-- `report-notify` edge function (mirrors the waitlist-signup email flow).

create extension if not exists pg_net with schema extensions;

create or replace function public.dispatch_report_notify()
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
    select decrypted_secret into fn_url from vault.decrypted_secrets where name = 'report_function_url';
    select decrypted_secret into fn_key from vault.decrypted_secrets where name = 'report_function_key';

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
        body    := jsonb_build_object('report_id', new.id)
    );
    return new;
end;
$$;

drop trigger if exists on_report_insert_notify on public.reports;
create trigger on_report_insert_notify
    after insert on public.reports
    for each row
    execute function public.dispatch_report_notify();

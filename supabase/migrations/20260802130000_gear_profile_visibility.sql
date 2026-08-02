-- Gear becomes something you display on your profile, with an owner switch.
--
-- Until now `gear_read` let any signed-in, non-blocked user read anyone's gear
-- rows, but nothing in the app ever surfaced another player's locker — gear was
-- world-readable and invisible at the same time, with no owner control. This
-- migration adds the control and narrows the policy to match it:
--
--   * `profiles.gear_visible` (default true) — "show my gear on my profile".
--   * gear is readable by a viewer only when the owner left it visible AND the
--     viewer can see that owner's profile content at all (public account, or an
--     accepted follow of a private one). Owners always read their own rows, so
--     hiding your locker never hides it from you.
--
-- Default true keeps every existing locker working the way it already did (the
-- old policy exposed all of them); the change is that hiding is now possible.

alter table public.profiles add column if not exists gear_visible boolean not null default true;

-- `private.profile_graph_visible` already encodes "self, or public account, or
-- accepted follower" for the private-accounts feature — reuse it rather than
-- re-deriving the follow check here.
drop policy if exists "gear_read" on public.gear;
create policy "gear_read" on public.gear
  for select to authenticated
  using (
    private.is_active_user((select auth.uid()))
    and not private.is_blocked_between((select auth.uid()), user_id)
    and (
      user_id = (select auth.uid())
      or (
        exists (
          select 1 from public.profiles p
          where p.id = gear.user_id and p.gear_visible
        )
        and private.profile_graph_visible((select auth.uid()), user_id)
      )
    )
  );

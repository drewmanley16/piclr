# pickleball.ai

Native SwiftUI MVP for a social pickleball logging app.

The current build includes:

- Supabase-backed phone OTP authentication
- First-run onboarding for profile, skill level, DUPR, and friend discovery
- Social feed scoped to you and accepted friends
- Practice session logging
- Gear locker and profile progress
- Supabase schema plus Edge Functions for onboarding and contact matching

## Open

```sh
open PickleballAI.xcodeproj
```

## Supabase Setup

1. Copy `PickleballAI/Supabase.example.plist` to `PickleballAI/Supabase.plist`.
2. Fill in `SUPABASE_URL` and `SUPABASE_ANON_KEY`.
3. Run `supabase/schema.sql` in the Supabase SQL editor.
4. Deploy the functions in `supabase/functions/complete-onboarding` and `supabase/functions/match-contacts`.

`Supabase.plist` is gitignored so local project credentials stay out of source control.

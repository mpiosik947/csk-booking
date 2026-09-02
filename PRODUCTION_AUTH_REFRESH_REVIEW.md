# CSK Booking — Production Auth Refresh Error Review

Date: 2026-09-02

Originally observed error:

```text
AuthApiError: Invalid Refresh Token: Refresh Token Not Found
```

## Final result

```text
ROOT CAUSE:
LIKELY — stale browser session/cookie whose refresh token no longer existed in Supabase Auth

CLEAN SESSION LOGIN:
PASS

SESSION REFRESH:
PASS

LOGOUT:
PASS

AUTH REFRESH ISSUE REPRODUCED:
NO

SECURITY IMPACT:
LOW

FIX REQUIRED:
NO
```

## Production verification

During controlled production smoke run `SECURITY-SMOKE-20260902T193153257Z-9E4686`, two newly created synthetic ordinary-user accounts independently completed the normal Supabase Auth lifecycle:

1. `signInWithPassword()`;
2. `auth.getUser()`;
3. explicit `refreshSession()`;
4. `signOut()`.

Every operation succeeded for both accounts. Neither account produced `Invalid Refresh Token: Refresh Token Not Found`, an Auth 5xx, a network failure, a false 401, or an unexpected logout.

The accounts were created with confirmed synthetic addresses only for this run and were deleted after successful logout. No real customer account or credential was used.

## Root-cause assessment

The new result strengthens the original assessment:

- the error occurred once in an older browser profile;
- it disappeared on subsequent tabs and reloads;
- it was not reproduced with two newly created sessions;
- normal token refresh and logout both worked;
- security remediation commit `d04c171` did not modify the browser client, middleware, callback, login, logout, or Booking Auth lifecycle.

The evidence remains most consistent with a stale or previously revoked refresh token retained by the older browser profile. Because the original cookie history was not available, the root cause remains `LIKELY`, not `CONFIRMED`.

## Impact and decision

No authentication bypass, session fixation, repeated refresh loop, production HTTP 5xx, or valid-session failure was observed. The original stale token failed closed and the application recovered to an unauthenticated state.

```text
SECURITY IMPACT: LOW
FIX REQUIRED: NO
```

No code, Auth configuration, database schema, RLS, ACL, migration, deployment, commit, or push was performed during this verification.

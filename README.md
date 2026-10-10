# Field

Field uses three isolated environments:

| Environment | Database | Mobile flavor | Git branch |
| --- | --- | --- | --- |
| Local | Docker Supabase on this laptop | `staging` + `APP_ENV=local` | Any |
| Staging | Field Staging | `staging` | `staging` |
| Production | Field Production | `production` | `prod` |

Local data is disposable. Staging contains test players and match scenarios.
Production contains real users and must never receive developer seeds.

## Start locally

```sh
supabase start
supabase db reset

cd mobile
flutter run --flavor staging --dart-define-from-file=.env.local
```

Hosted staging:

```sh
cd mobile
flutter run --flavor staging --dart-define-from-file=.env.staging
```

Production:

```sh
cd mobile
flutter run --flavor production --dart-define-from-file=.env.production
```

The app refuses a flavor/database mismatch. Local and staging builds display a
visible environment ribbon.

The referee/admin app uses `NEXT_PUBLIC_APP_ENV` and the same exact-project
guard. It also shows a permanent LOCAL or STAGING ribbon and refuses an
unknown environment.

CI replays every migration from zero and runs a real Open Queue lifecycle
against disposable local Supabase. After a staging deploy, the protected
workflow creates uniquely tagged test accounts and games, runs the Android
player journey plus referee/admin browser journey, verifies the resulting
database state, and cleans all mutable test state. Production promotion remains
blocked unless that complete staging E2E gate succeeds.

See [mobile/README.md](mobile/README.md) for app commands and
[.github/DEPLOYMENT.md](.github/DEPLOYMENT.md) for CI/CD setup, required
GitHub secrets, promotion, and production safeguards.

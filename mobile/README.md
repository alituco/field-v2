# Field Mobile

Flutter app for Field.

## Run

From this directory:

```sh
flutter run --dart-define-from-file=.env.mobile
```

The app expects these values in `mobile/.env.mobile`:

```sh
SUPABASE_URL=
SUPABASE_PUBLISHABLE_KEY=
DEV=true
```

Use the Supabase publishable key in the app. Never put a secret or service-role
key in Flutter. Do not pass the repo root `.env` into Flutter builds.

`DEV=true` enables development-only tools such as switching users from the
Profile screen. Remove it or set it to `false` for production builds.

## Test

```sh
flutter analyze
flutter test
```

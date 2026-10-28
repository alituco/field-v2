-- A linked Google identity is proof of its own verified email, even when Auth's
-- primary email predates manual identity linking. Never use editable user metadata
-- as email proof, and never write directly to Auth's identity/user tables.
create function fieldrush_private.linked_google_email(caller uuid)
returns text language sql stable security definer
set search_path=pg_catalog,auth,pg_temp as $$
  select lower(btrim(i.identity_data->>'email'))
  from auth.identities i
  where i.user_id=caller and i.provider='google'
    and i.identity_data->'email_verified'='true'::jsonb
    and jsonb_typeof(i.identity_data->'email')='string'
    and char_length(btrim(i.identity_data->>'email')) between 3 and 254
    and btrim(i.identity_data->>'email') ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
  order by i.created_at,i.id
  limit 1;
$$;
revoke all on function fieldrush_private.linked_google_email(uuid)
  from public,anon,authenticated,service_role;

-- Keep the current account/city/assessment wrapper chain intact. This projection
-- is read-only: a settings read must not silently overwrite a saved draft.
alter function public.get_my_fieldrush_account()
  rename to get_my_fieldrush_account_before_google_contact;
revoke all on function public.get_my_fieldrush_account_before_google_contact()
  from public,anon,authenticated,service_role;
create function public.get_my_fieldrush_account()
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,fieldrush_private,pg_temp as $$
declare
  caller uuid:=fieldrush_private.require_user();
  result jsonb;
  google_email text;
begin
  result:=public.get_my_fieldrush_account_before_google_contact();
  google_email:=fieldrush_private.linked_google_email(caller);
  result:=result||jsonb_build_object('google_email',google_email);
  if google_email is not null then
    result:=result||jsonb_build_object('email',google_email,'email_verified',true);
  end if;
  return result;
end;
$$;
revoke all on function public.get_my_fieldrush_account() from public,anon;
grant execute on function public.get_my_fieldrush_account() to authenticated;

-- Settings cannot silently replace a linked Google's contact email. The client
-- must obtain consent, retain a verified phone identity, and unlink through Auth
-- before saving a different address. Onboarding drafts remain backwards compatible;
-- their effective address is still the trusted Google address returned above.
create or replace function public.update_my_fieldrush_account(draft jsonb)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,fieldrush_private,pg_temp as $$
declare
  caller uuid:=fieldrush_private.require_user();
  normalized jsonb:=fieldrush_private.validate_draft(draft);
  google_email text:=fieldrush_private.linked_google_email(caller);
begin
  if google_email is not null and normalized->>'email' is distinct from google_email then
    raise exception 'Disconnect Google before changing your email. Your verified phone number is required to keep signing in.'
      using errcode='22023';
  end if;
  perform fieldrush_private.write_account(draft,false);
  return public.get_my_fieldrush_account();
end;
$$;
revoke all on function public.update_my_fieldrush_account(jsonb) from public,anon;
grant execute on function public.update_my_fieldrush_account(jsonb) to authenticated;

notify pgrst,'reload schema';

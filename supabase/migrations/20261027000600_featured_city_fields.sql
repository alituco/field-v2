-- Each competition city can choose one saved field for its discovery card.
-- The field catalog remains private; players receive only public directions.
alter table public.fieldrush_cities add column featured_field_id uuid
  references public.fields(id) on delete set null;

create function public.get_featured_field(city_id_to_use text)
returns jsonb language plpgsql stable security definer
set search_path=public,pg_temp as $$
begin
  if auth.uid() is null then raise exception 'You need to sign in again.'; end if;
  return (
    select jsonb_build_object(
      'id',f.id,'name',f.name,'address',f.address,'city',f.city,'state',f.state,
      'country_code',f.country_code,'latitude',f.latitude,'longitude',f.longitude,
      'market_city_id',f.market_city_id
    )
    from public.fieldrush_cities c join public.fields f
      on f.id=c.featured_field_id and f.market_city_id=c.id and f.is_active
    where c.id=city_id_to_use and c.active
  );
end;
$$;
revoke all on function public.get_featured_field(text) from public,anon;
grant execute on function public.get_featured_field(text) to authenticated,service_role;

create function public.admin_set_featured_field(
  actor_admin_id uuid,city_id_to_use text,field_id_to_use uuid,featured_to_use boolean
)
returns jsonb language plpgsql security definer
set search_path=public,pg_temp as $$
declare saved_field public.fields%rowtype; city public.fieldrush_cities%rowtype;
  previous_id uuid; next_id uuid;
begin
  if not coalesce(public.is_active_moderation_admin(actor_admin_id),false) then
    raise exception 'Admin referee access required.';
  end if;
  if featured_to_use is null then raise exception 'Choose whether to feature this field.'; end if;
  -- Field-first locking matches field edits and their city validation trigger.
  -- Holding this share lock prevents a move/archive racing the city selection.
  select * into saved_field from public.fields where id=field_id_to_use for share;
  if saved_field.id is null then raise exception 'Choose a saved field.'; end if;
  if saved_field.market_city_id is distinct from city_id_to_use then
    raise exception 'This field belongs to another competition city. Reload the fields.';
  end if;
  select * into city from public.fieldrush_cities where id=city_id_to_use for update;
  if city.id is null then raise exception 'Choose an available city.'; end if;
  if featured_to_use and (not city.active or not saved_field.is_active) then
    raise exception 'Choose an active field in an available city.';
  end if;
  previous_id:=city.featured_field_id;
  if not featured_to_use and previous_id is not null and previous_id<>field_id_to_use then
    raise exception 'The featured field changed. Reload before removing its feature.';
  end if;
  next_id:=case when featured_to_use then field_id_to_use else null end;
  if next_id is distinct from previous_id then
    update public.fieldrush_cities set featured_field_id=next_id where id=city.id;
    insert into public.admin_audit_events(
      actor_referee_id,action,entity_type,entity_id,reason,before_state,after_state
    ) values(
      actor_admin_id,'FEATURED_FIELD_CHANGED','ACTION',field_id_to_use,
      'Admin changed the field shown in the player app.',
      jsonb_build_object('city_id',city.id,'featured_field_id',previous_id),
      jsonb_build_object('city_id',city.id,'featured_field_id',next_id)
    );
  end if;
  return jsonb_build_object('city_id',city.id,'featured_field_id',next_id);
end;
$$;
revoke all on function public.admin_set_featured_field(uuid,text,uuid,boolean)
  from public,anon,authenticated;
grant execute on function public.admin_set_featured_field(uuid,text,uuid,boolean) to service_role;

comment on function public.get_featured_field(text) is
  'Signed-in discovery card: current public address and directions for the selected active field in an active competition city.';
notify pgrst,'reload schema';

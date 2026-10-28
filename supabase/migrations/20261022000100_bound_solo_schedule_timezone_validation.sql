-- A booking changes OPEN to FULL without changing its saved timezone. Expanding
-- the whole PostgreSQL timezone catalogue again on every such update can use a
-- substantial part of the atomic booking's statement budget. Validate a new
-- timezone only when it is introduced; retain every other scheduling guard.
do $migration$
declare definition text; anchor text;
begin
  definition:=pg_get_functiondef('public.enforce_open_queue_permanent_schedule()'::regprocedure);
  anchor:='    if not exists(select 1 from pg_timezone_names where name=new.timezone) then raise exception ''Choose a valid game timezone.''; end if;';
  if position(anchor in definition)=0 then
    raise exception 'Solo schedule timezone validation contract changed.';
  end if;
  definition:=replace(definition,anchor,$replacement$
    if tg_op='INSERT' or new.timezone is distinct from old.timezone then
      if not exists(select 1 from pg_timezone_names where name=new.timezone) then
        raise exception 'Choose a valid game timezone.';
      end if;
    end if;$replacement$);
  execute definition;
end;
$migration$;

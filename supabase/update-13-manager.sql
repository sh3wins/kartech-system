-- =====================================================================
--  KARTECH UPDATE 13: "Foreman" is now called "Manager"
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Safe to run again. Only words change, nothing else.
-- =====================================================================

-- the messages the system writes (History, workshop news, errors)
do $$
declare f record; src text; fixed text;
begin
  for f in select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.prokind = 'f' loop
    src := pg_get_functiondef(f.oid);
    fixed := replace(replace(replace(replace(replace(replace(replace(src,
      'Foreman gave ', 'Manager gave '),
      'Foreman added a new worker', 'Manager added a new worker'),
      'Foreman updated ', 'Manager updated '),
      'Foreman code changed', 'Manager code changed'),
      'by foreman', 'by manager'),
      'wrong foreman code', 'wrong manager code'),
      'set a foreman code', 'set a manager code');
    if fixed <> src then execute fixed; end if;
  end loop;
end $$;

-- old entries in History read the new way too
update public.ws_log set text = replace(replace(replace(replace(replace(text,
  'Foreman gave ', 'Manager gave '), 'Foreman added a new worker', 'Manager added a new worker'),
  'Foreman updated ', 'Manager updated '), 'Foreman code changed', 'Manager code changed'),
  'wrong foreman code', 'wrong manager code')
 where text ~ '(Foreman (gave|added|updated|code changed)|wrong foreman code)';
update public.ws_moves set note = replace(note, 'by foreman', 'by manager') where note like '%by foreman%';

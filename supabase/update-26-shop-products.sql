-- =====================================================================
--  UPDATE 26: the owner runs the website shop from her app
--  • A list of shop products (name, price, photos, category…) that the
--    owner adds and edits in the app (Stock → Shop products).
--  • The website shop reads this list, so a new product or photo shows
--    for customers straight away.
--  • A public photo folder "shop-photos": anyone can see the pictures
--    (they are on the website), only the owner can add or remove them.
--  Prices here are the public shop prices that customers see.
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Safe to run again.
-- =====================================================================
create table if not exists public.kt_products (
  id          text primary key,
  name        text not null,
  price       numeric check (price is null or price >= 0),   -- empty = "Price on request"
  images      text[] not null default '{}',                    -- first one is the main photo
  tags        text[] not null default '{}',                    -- shop tabs: Furniture, Waiting seats, Catering equipment, Outdoor
  space       text,                                            -- small label under the name, e.g. "Bars & cafés"
  material    text,
  finishes    jsonb not null default '[]',                      -- colour choices: [{"name":"Black","color":"#2b2820"}]
  availability text,
  about       text, dimensions text, materials text, care text, delivery text,
  sort        int not null default 0,                          -- smaller shows first
  active      boolean not null default true,                    -- false = hidden from the website
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
alter table public.kt_products enable row level security;
drop policy if exists "shop products visible" on public.kt_products;
create policy "shop products visible" on public.kt_products for select to anon, authenticated
  using (active or public.is_admin());
grant select on public.kt_products to anon, authenticated;
revoke insert, update, delete on public.kt_products from anon, authenticated;

-- add or change a product (owner only). p = {id?, name, price, images[], tags[], space, material, about, availability, active, …}
create or replace function public.kt_save_product(p jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare v_id text := nullif(trim(coalesce(p->>'id', '')), ''); v_name text := left(trim(coalesce(p->>'name', '')), 120);
        v_price numeric; base text; n int := 1;
begin
  perform public.ws_need_owner();
  if v_name = '' then raise exception 'Give the product a name'; end if;
  if nullif(trim(coalesce(p->>'price', '')), '') is not null then
    begin v_price := (p->>'price')::numeric; exception when others then raise exception 'The price must be a number'; end;
    if v_price < 0 then raise exception 'The price cannot be below 0'; end if;
  end if;
  if jsonb_array_length(coalesce(p->'images', '[]')) > 8 then raise exception 'Up to 8 photos per product'; end if;
  if v_id is null or not exists (select 1 from public.kt_products where id = v_id) then
    if v_id is null then
      base := trim(both '-' from regexp_replace(lower(v_name), '[^a-z0-9]+', '-', 'g'));
      if base = '' then base := 'product'; end if;
      v_id := base;
      while exists (select 1 from public.kt_products where id = v_id) loop n := n + 1; v_id := base || '-' || n; end loop;
    end if;
    insert into public.kt_products (id, name, sort) values (v_id, v_name, coalesce((select min(sort) from public.kt_products), 0) - 1);
  end if;
  update public.kt_products set
    name = v_name, price = v_price,
    images = coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(p->'images', '[]')) x where trim(x) <> ''), '{}'),
    tags = coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(p->'tags', '[]')) x where trim(x) <> ''), '{}'),
    space = nullif(left(trim(coalesce(p->>'space', '')), 80), ''),
    material = nullif(left(trim(coalesce(p->>'material', '')), 160), ''),
    finishes = case when p ? 'finishes' then coalesce(p->'finishes', '[]') else finishes end,
    availability = nullif(left(trim(coalesce(p->>'availability', '')), 60), ''),
    about = nullif(left(trim(coalesce(p->>'about', '')), 1500), ''),
    dimensions = case when p ? 'dimensions' then nullif(left(trim(p->>'dimensions'), 400), '') else dimensions end,
    materials = case when p ? 'materials' then nullif(left(trim(p->>'materials'), 400), '') else materials end,
    care = case when p ? 'care' then nullif(left(trim(p->>'care'), 400), '') else care end,
    delivery = case when p ? 'delivery' then nullif(left(trim(p->>'delivery'), 400), '') else delivery end,
    active = coalesce((p->>'active')::boolean, active),
    updated_at = now()
  where id = v_id;
  return v_id;
end $$;

-- delete a product for good (owner only). Returns its uploaded photo paths so the app can tidy the photo folder.
create or replace function public.kt_delete_product(p_id text) returns text[]
language plpgsql security definer set search_path = public as $$
declare imgs text[];
begin
  perform public.ws_need_owner();
  delete from public.kt_products where id = p_id returning images into imgs;
  return coalesce(imgs, '{}');
end $$;

-- move a product to the top or bottom of the shop (owner only)
create or replace function public.kt_move_product(p_id text, p_to text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.ws_need_owner();
  update public.kt_products set sort = case when p_to = 'bottom' then coalesce((select max(sort) from public.kt_products), 0) + 1
                                             else coalesce((select min(sort) from public.kt_products), 0) - 1 end,
         updated_at = now() where id = p_id;
end $$;

revoke all on function public.kt_save_product(jsonb), public.kt_delete_product(text), public.kt_move_product(text, text) from public, anon;
grant execute on function public.kt_save_product(jsonb), public.kt_delete_product(text), public.kt_move_product(text, text) to authenticated;

-- the public photo folder for shop products
do $do$
begin
  if exists (select 1 from information_schema.schemata where schema_name = 'storage') then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('shop-photos', 'shop-photos', true, 10485760, array['image/jpeg','image/png','image/webp'])
    on conflict (id) do update set public = true, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;
    drop policy if exists "shop photos owner add"    on storage.objects;
    drop policy if exists "shop photos owner remove" on storage.objects;
    create policy "shop photos owner add" on storage.objects for insert to authenticated
      with check (bucket_id = 'shop-photos' and public.is_admin());
    create policy "shop photos owner remove" on storage.objects for delete to authenticated
      using (bucket_id = 'shop-photos' and public.is_admin());
  end if;
end $do$;

-- the products already on the website (added once; the owner edits them from now on)
insert into public.kt_products (id,name,price,images,tags,space,material,finishes,availability,about,dimensions,materials,care,delivery,sort) values
('tube-arm-chair-brown','Tube-Arm Dining Chair',null,array['photos/tube-arm-chair-brown.jpg']::text[],array['Furniture']::text[],'Restaurants & cafés','Bent steel tube frame · brown leatherette','[]'::jsonb,'In stock','Made in the Kartech workshop. Ask us about colours, quantities and custom sizes.','Ask us for the exact sizes.','Bent steel tube frame · brown leatherette.','Wipe with a damp cloth. Avoid harsh chemicals on the seat.','Delivery across Kenya. Cost and timing confirmed with your order.',0),
('visitor-armchair-blue','Padded Visitor Armchair',null,array['photos/visitor-armchair-blue.jpg']::text[],array['Waiting seats']::text[],'Offices & waiting areas','Steel frame · blue fabric','[]'::jsonb,'In stock','Made in the Kartech workshop. Ask us about colours, quantities and custom sizes.','Ask us for the exact sizes.','Steel frame · blue fabric.','Wipe with a damp cloth. Avoid harsh chemicals on the seat.','Delivery across Kenya. Cost and timing confirmed with your order.',1),
('cross-back-cafe-chair','Cross-Back Café Chair',null,array['photos/cross-back-cafe-chair.jpg']::text[],array['Furniture']::text[],'Restaurants & cafés','Bronze-finish steel · padded round seat','[]'::jsonb,'In stock','Made in the Kartech workshop. Ask us about colours, quantities and custom sizes.','Ask us for the exact sizes.','Bronze-finish steel · padded round seat.','Wipe with a damp cloth. Avoid harsh chemicals on the seat.','Delivery across Kenya. Cost and timing confirmed with your order.',2),
('studded-dining-chair-tan','Studded-Frame Dining Chair',null,array['photos/studded-dining-chair-tan.jpg']::text[],array['Furniture']::text[],'Restaurants & hotels','Hammered-finish steel · tan leatherette','[]'::jsonb,'In stock','Made in the Kartech workshop. Ask us about colours, quantities and custom sizes.','Ask us for the exact sizes.','Hammered-finish steel · tan leatherette.','Wipe with a damp cloth. Avoid harsh chemicals on the seat.','Delivery across Kenya. Cost and timing confirmed with your order.',3),
('two-tone-high-back-chair','Two-Tone High-Back Chair',null,array['photos/two-tone-high-back-chair.jpg']::text[],array['Furniture']::text[],'Restaurants & bars','Steel frame · two-colour leatherette','[]'::jsonb,'In stock','Made in the Kartech workshop. Ask us about colours, quantities and custom sizes.','Ask us for the exact sizes.','Steel frame · two-colour leatherette.','Wipe with a damp cloth. Avoid harsh chemicals on the seat.','Delivery across Kenya. Cost and timing confirmed with your order.',4),
('round-back-cafe-chair','Round-Back Café Chair',null,array['photos/round-back-cafe-chair.jpg']::text[],array['Furniture']::text[],'Restaurants & cafés','Bronze-finish steel · brown leatherette','[]'::jsonb,'In stock','Made in the Kartech workshop. Ask us about colours, quantities and custom sizes.','Ask us for the exact sizes.','Bronze-finish steel · brown leatherette.','Wipe with a damp cloth. Avoid harsh chemicals on the seat.','Delivery across Kenya. Cost and timing confirmed with your order.',5),
('rope-bar-chair-zebra','Rope-Back Bar Chair, Zebra Seat',null,array['photos/rope-bar-chair-zebra.jpg']::text[],array['Furniture']::text[],'Bars & lounges','Steel frame · woven rope · zebra-print seat','[]'::jsonb,'In stock','Made in the Kartech workshop. Ask us about colours, quantities and custom sizes.','Ask us for the exact sizes.','Steel frame · woven rope · zebra-print seat.','Wipe with a damp cloth. Avoid harsh chemicals on the seat.','Delivery across Kenya. Cost and timing confirmed with your order.',6),
('rope-lounge-zebra-cushions','Rope Lounge Chair with Zebra Cushions',null,array['photos/rope-lounge-zebra-cushions.jpg']::text[],array['Outdoor']::text[],'Lounges & terraces','Steel frame · woven rope · zebra-print cushions','[]'::jsonb,'In stock','Made in the Kartech workshop. Ask us about colours, quantities and custom sizes.','Ask us for the exact sizes.','Steel frame · woven rope · zebra-print cushions.','Wipe with a damp cloth. Avoid harsh chemicals on the seat.','Delivery across Kenya. Cost and timing confirmed with your order.',7),
('rope-back-bar-stool','Rope-Back Bar Stool',null,array['photos/rope-back-bar-stool.jpg']::text[],array['Furniture']::text[],'Bars & cafés','Hammered-finish steel · rope back · leatherette seat','[]'::jsonb,'In stock','Made in the Kartech workshop. Ask us about colours, quantities and custom sizes.','Ask us for the exact sizes.','Hammered-finish steel · rope back · leatherette seat.','Wipe with a damp cloth. Avoid harsh chemicals on the seat.','Delivery across Kenya. Cost and timing confirmed with your order.',8),
('red-bar-stool','Round-Seat Bar Stool, Red',null,array['photos/red-bar-stool.jpg']::text[],array['Furniture']::text[],'Bars & cafés','Hammered-finish steel · red leatherette','[]'::jsonb,'In stock','Made in the Kartech workshop. Ask us about colours, quantities and custom sizes.','Ask us for the exact sizes.','Hammered-finish steel · red leatherette.','Wipe with a damp cloth. Avoid harsh chemicals on the seat.','Delivery across Kenya. Cost and timing confirmed with your order.',9),
('classic-dining-chair-cream','Classic Dining Chair, Cream',null,array['photos/classic-dining-chair-cream.jpg']::text[],array['Furniture']::text[],'Restaurants & hotels','Hammered-finish steel · cream leatherette','[]'::jsonb,'In stock','Made in the Kartech workshop. Ask us about colours, quantities and custom sizes.','Ask us for the exact sizes.','Hammered-finish steel · cream leatherette.','Wipe with a damp cloth. Avoid harsh chemicals on the seat.','Delivery across Kenya. Cost and timing confirmed with your order.',10),
('padded-dining-chair-black','Padded Dining Chair, Black',null,array['photos/padded-dining-chair-black.jpg']::text[],array['Furniture']::text[],'Restaurants & cafés','Silver-finish steel · black leatherette','[]'::jsonb,'In stock','Made in the Kartech workshop. Ask us about colours, quantities and custom sizes.','Ask us for the exact sizes.','Silver-finish steel · black leatherette.','Wipe with a damp cloth. Avoid harsh chemicals on the seat.','Delivery across Kenya. Cost and timing confirmed with your order.',11),
('laser-cut-armchair','Laser-Cut Back Armchair',null,array['photos/laser-cut-armchair.jpg']::text[],array['Furniture']::text[],'Restaurants & terraces','Cut-steel back · padded seat','[]'::jsonb,'In stock','Made in the Kartech workshop. Ask us about colours, quantities and custom sizes.','Ask us for the exact sizes.','Cut-steel back · padded seat.','Wipe with a damp cloth. Avoid harsh chemicals on the seat.','Delivery across Kenya. Cost and timing confirmed with your order.',12),
('rope-lounge-armchair-beige','Rope Lounge Armchair, Beige',null,array['photos/rope-lounge-armchair-beige.jpg']::text[],array['Outdoor']::text[],'Lounges & terraces','Steel frame · woven rope · beige cushions','[]'::jsonb,'In stock','Made in the Kartech workshop. Ask us about colours, quantities and custom sizes.','Ask us for the exact sizes.','Steel frame · woven rope · beige cushions.','Wipe with a damp cloth. Avoid harsh chemicals on the seat.','Delivery across Kenya. Cost and timing confirmed with your order.',13),
('curved-arm-chair-tan','Curved-Arm Lounge Chair, Tan',null,array['photos/curved-arm-chair-tan.jpg']::text[],array['Furniture']::text[],'Lounges & offices','Steel frame · tan leatherette','[]'::jsonb,'In stock','Made in the Kartech workshop. Ask us about colours, quantities and custom sizes.','Ask us for the exact sizes.','Steel frame · tan leatherette.','Wipe with a damp cloth. Avoid harsh chemicals on the seat.','Delivery across Kenya. Cost and timing confirmed with your order.',14),
('striped-high-back-chair','Striped High-Back Chair',null,array['photos/striped-high-back-chair.jpg']::text[],array['Furniture']::text[],'Restaurants & bars','Steel frame · red and white leatherette','[]'::jsonb,'In stock','Made in the Kartech workshop. Ask us about colours, quantities and custom sizes.','Ask us for the exact sizes.','Steel frame · red and white leatherette.','Wipe with a damp cloth. Avoid harsh chemicals on the seat.','Delivery across Kenya. Cost and timing confirmed with your order.',15),
('branded-church-chair','Church Chair with Printed Logo',null,array['photos/branded-church-chair.jpg','photos/branded-church-chair-2.jpg']::text[],array['Waiting seats']::text[],'Churches & halls','Steel frame · fabric · your logo printed on the back','[]'::jsonb,'In stock','Made in the Kartech workshop. Ask us about colours, quantities and custom sizes.','Ask us for the exact sizes.','Steel frame · fabric · your logo printed on the back.','Wipe with a damp cloth. Avoid harsh chemicals on the seat.','Delivery across Kenya. Cost and timing confirmed with your order.',16),
('grey-dining-chair','Grey Dining Chair',null,array['photos/grey-dining-chair.jpg']::text[],array['Furniture']::text[],'Restaurants & canteens','Steel frame · grey leatherette','[]'::jsonb,'In stock','Made in the Kartech workshop. Ask us about colours, quantities and custom sizes.','Ask us for the exact sizes.','Steel frame · grey leatherette.','Wipe with a damp cloth. Avoid harsh chemicals on the seat.','Delivery across Kenya. Cost and timing confirmed with your order.',17),
('high-back-bar-chair-rust','High-Back Bar Chair, Rust',null,array['photos/high-back-bar-chair-rust.jpg']::text[],array['Furniture']::text[],'Bars & lounges','Steel frame · rust leatherette','[]'::jsonb,'In stock','Made in the Kartech workshop. Ask us about colours, quantities and custom sizes.','Ask us for the exact sizes.','Steel frame · rust leatherette.','Wipe with a damp cloth. Avoid harsh chemicals on the seat.','Delivery across Kenya. Cost and timing confirmed with your order.',18),
('banquet-chair-gold','Banquet Chair, Gold Frame',null,array['photos/banquet-chair-gold.jpg']::text[],array['Furniture']::text[],'Weddings, events & halls','Gold-finish steel · patterned fabric','[]'::jsonb,'In stock','Made in the Kartech workshop. Ask us about colours, quantities and custom sizes.','Ask us for the exact sizes.','Gold-finish steel · patterned fabric.','Wipe with a damp cloth. Avoid harsh chemicals on the seat.','Delivery across Kenya. Cost and timing confirmed with your order.',19),
('rope-armchair-brown','Rope Armchair, Brown Seat',null,array['photos/rope-armchair-brown.jpg']::text[],array['Outdoor']::text[],'Restaurants & terraces','Hammered-finish steel · woven rope · brown leatherette','[]'::jsonb,'In stock','Made in the Kartech workshop. Ask us about colours, quantities and custom sizes.','Ask us for the exact sizes.','Hammered-finish steel · woven rope · brown leatherette.','Wipe with a damp cloth. Avoid harsh chemicals on the seat.','Delivery across Kenya. Cost and timing confirmed with your order.',20),
('oval-back-cafe-chair-cream','Oval-Back Café Chair, Cream',null,array['photos/oval-back-cafe-chair-cream.jpg']::text[],array['Furniture']::text[],'Restaurants & cafés','Bronze-finish steel · cream leatherette','[]'::jsonb,'In stock','Made in the Kartech workshop. Ask us about colours, quantities and custom sizes.','Ask us for the exact sizes.','Bronze-finish steel · cream leatherette.','Wipe with a damp cloth. Avoid harsh chemicals on the seat.','Delivery across Kenya. Cost and timing confirmed with your order.',21),
('dining-set','Restaurant Dining Set',null,array[]::text[],array['Furniture']::text[],'Restaurants','Steel frame · [top material — to confirm]','[{"name":"Black","color":"#2b2820"},{"name":"Grey","color":"#8B8D89"},{"name":"White","color":"#EDEBE6"},{"name":"Green","color":"#3F5A3D"}]'::jsonb,null,'A table with matching chairs for restaurants and cafés. Ordered in the quantity your space needs. [Real description — to confirm]','[Table and chair sizes — to confirm]','[Frame, top and seat details — to confirm]','[Care instructions — to confirm with Kartech]','Delivery across Kenya. Cost and timing confirmed with your order.',22),
('bar-stool','Bar Stool',null,array[]::text[],array['Furniture']::text[],'Bars & cafés','Steel frame · [seat — to confirm]','[{"name":"Black","color":"#2b2820"},{"name":"Grey","color":"#8B8D89"},{"name":"White","color":"#EDEBE6"},{"name":"Green","color":"#3F5A3D"}]'::jsonb,null,'A high stool for bar counters and high tables. [Real description — to confirm]','[Seat height — to confirm]','[Frame and seat details — to confirm]','[Care instructions — to confirm with Kartech]','Delivery across Kenya. Cost and timing confirmed with your order.',23),
('high-table-set','High Table Set',null,array[]::text[],array['Furniture']::text[],'Bars & cafés','Steel frame · [top — to confirm]','[{"name":"Black","color":"#2b2820"},{"name":"Grey","color":"#8B8D89"},{"name":"White","color":"#EDEBE6"},{"name":"Green","color":"#3F5A3D"}]'::jsonb,null,'A high table with matching bar stools. [Real description — to confirm]','[Table height and top size — to confirm]','[Frame and top details — to confirm]','[Care instructions — to confirm with Kartech]','Delivery across Kenya. Cost and timing confirmed with your order.',24),
('church-chair','Church Chair',null,array[]::text[],array['Furniture']::text[],'Churches & halls','Steel frame · padded seat','[{"name":"Black","color":"#2b2820"},{"name":"Grey","color":"#8B8D89"},{"name":"Blue","color":"#2F4A7A"},{"name":"Red","color":"#8E2A22"}]'::jsonb,null,'Seating for churches, halls and events, made in large quantities. [Real description — to confirm]','[Seat size — to confirm]','[Frame, foam and fabric — to confirm]','[Care instructions — to confirm with Kartech]','Delivery across Kenya. Cost and timing confirmed with your order.',25),
('school-desk','School Desk and Chair',null,array[]::text[],array['Furniture']::text[],'Schools','Steel frame · [top — to confirm]','[{"name":"Black","color":"#2b2820"},{"name":"Grey","color":"#8B8D89"},{"name":"White","color":"#EDEBE6"},{"name":"Green","color":"#3F5A3D"}]'::jsonb,null,'Strong desks and chairs for classrooms. [Real description — to confirm]','[Sizes by age — to confirm]','[Frame and top details — to confirm]','[Care instructions — to confirm with Kartech]','Delivery across Kenya. Cost and timing confirmed with your order.',26),
('outdoor-lounge-set','Outdoor Lounge Set',null,array[]::text[],array['Furniture','Outdoor']::text[],'Outdoor','Steel frame · outdoor cushions','[{"name":"Black","color":"#2b2820"},{"name":"Grey","color":"#8B8D89"},{"name":"White","color":"#EDEBE6"},{"name":"Green","color":"#3F5A3D"}]'::jsonb,null,'Sofas and a table for terraces, gardens and hotels. [Real description — to confirm]','[Sizes — to confirm]','[Frame and cushion details — to confirm]','[Care instructions — to confirm with Kartech]','Delivery across Kenya. Cost and timing confirmed with your order.',27),
('waiting-bench-3','3-Seater Waiting Bench',null,array[]::text[],array['Waiting seats']::text[],'Hospitals, banks & offices','Steel beam · [seat type — to confirm]','[{"name":"Black","color":"#2b2820"},{"name":"Grey","color":"#8B8D89"},{"name":"Blue","color":"#2F4A7A"},{"name":"Red","color":"#8E2A22"}]'::jsonb,null,'Linked metal seating for reception and waiting areas. [Real description — to confirm]','[Length and seat height — to confirm]','[Beam, legs and seats — to confirm]','[Care instructions — to confirm with Kartech]','Delivery across Kenya. Cost and timing confirmed with your order.',28),
('waiting-bench-4','4-Seater Waiting Bench',null,array[]::text[],array['Waiting seats']::text[],'Hospitals, banks & offices','Steel beam · [seat type — to confirm]','[{"name":"Black","color":"#2b2820"},{"name":"Grey","color":"#8B8D89"},{"name":"Blue","color":"#2F4A7A"},{"name":"Red","color":"#8E2A22"}]'::jsonb,null,'Linked metal seating for reception and waiting areas. [Real description — to confirm]','[Length and seat height — to confirm]','[Beam, legs and seats — to confirm]','[Care instructions — to confirm with Kartech]','Delivery across Kenya. Cost and timing confirmed with your order.',29),
('waiting-bench-5','5-Seater Waiting Bench',null,array[]::text[],array['Waiting seats']::text[],'Hospitals, banks & offices','Steel beam · [seat type — to confirm]','[{"name":"Black","color":"#2b2820"},{"name":"Grey","color":"#8B8D89"},{"name":"Blue","color":"#2F4A7A"},{"name":"Red","color":"#8E2A22"}]'::jsonb,null,'Linked metal seating for larger waiting halls. [Real description — to confirm]','[Length and seat height — to confirm]','[Beam, legs and seats — to confirm]','[Care instructions — to confirm with Kartech]','Delivery across Kenya. Cost and timing confirmed with your order.',30),
('gas-cooker-2','Two-Burner Gas Cooker',null,array[]::text[],array['Catering equipment']::text[],'Commercial kitchens','Stainless steel','[{"name":"Stainless steel","color":"#C9CBC8"}]'::jsonb,null,'A high-pressure gas cooker for restaurant, hotel and school kitchens. [Real description — to confirm]','[Width × depth × height — to confirm]','[Steel grade and burner type — to confirm]','[Care instructions — to confirm with Kartech]','Delivery across Kenya. Cost and timing confirmed with your order.',31),
('gas-cooker-3','Three-Burner Gas Cooker',null,array[]::text[],array['Catering equipment']::text[],'Commercial kitchens','Stainless steel','[{"name":"Stainless steel","color":"#C9CBC8"}]'::jsonb,null,'A larger high-pressure gas cooker for busy kitchens. [Real description — to confirm]','[Width × depth × height — to confirm]','[Steel grade and burner type — to confirm]','[Care instructions — to confirm with Kartech]','Delivery across Kenya. Cost and timing confirmed with your order.',32),
('cooker-griddle','Gas Cooker with Griddle',null,array[]::text[],array['Catering equipment']::text[],'Commercial kitchens','Stainless steel','[{"name":"Stainless steel","color":"#C9CBC8"}]'::jsonb,null,'Burners and a flat griddle in one unit. [Real description — to confirm]','[Width × depth × height — to confirm]','[Steel grade and burner type — to confirm]','[Care instructions — to confirm with Kartech]','Delivery across Kenya. Cost and timing confirmed with your order.',33),
('stockpot-burner','Single Stock Pot Burner',null,array[]::text[],array['Catering equipment']::text[],'Commercial kitchens','Stainless steel','[{"name":"Stainless steel","color":"#C9CBC8"}]'::jsonb,null,'A low, heavy burner for large cooking pots. [Real description — to confirm]','[Width × depth × height — to confirm]','[Steel grade and burner type — to confirm]','[Care instructions — to confirm with Kartech]','Delivery across Kenya. Cost and timing confirmed with your order.',34)
on conflict (id) do nothing;

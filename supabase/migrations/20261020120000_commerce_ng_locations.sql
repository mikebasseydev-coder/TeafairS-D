-- Spec D1 §3.1 — global reference tables: Nigerian states and LGAs.
-- Shared by all tenants like retail_shops. SELECT to authenticated; no write
-- grants and no write policies. State codes are ISO 3166-2:NG; LGA names are
-- INEC's list of 774. LGA ids are deterministic (md5 of state and name) so
-- every environment seeds identical keys.

create table public.ng_states (
  code text primary key check (code ~ '^[A-Z]{2}$'),
  name text not null unique
);
alter table public.ng_states enable row level security;
create policy ng_states_select on public.ng_states
  for select to authenticated using (true);
grant select on public.ng_states to authenticated;

create table public.ng_lgas (
  id         uuid primary key,
  state_code text not null references public.ng_states (code) on delete restrict,
  name       text not null check (length(btrim(name)) > 0),
  unique (state_code, name)
);
alter table public.ng_lgas enable row level security;
create policy ng_lgas_select on public.ng_lgas
  for select to authenticated using (true);
grant select on public.ng_lgas to authenticated;

insert into public.ng_states (code, name) values
  ('AB', 'Abia'), ('AD', 'Adamawa'), ('AK', 'Akwa Ibom'), ('AN', 'Anambra'),
  ('BA', 'Bauchi'), ('BY', 'Bayelsa'), ('BE', 'Benue'), ('BO', 'Borno'),
  ('CR', 'Cross River'), ('DE', 'Delta'), ('EB', 'Ebonyi'), ('ED', 'Edo'),
  ('EK', 'Ekiti'), ('EN', 'Enugu'), ('FC', 'Federal Capital Territory'),
  ('GO', 'Gombe'), ('IM', 'Imo'), ('JI', 'Jigawa'), ('KD', 'Kaduna'),
  ('KN', 'Kano'), ('KT', 'Katsina'), ('KE', 'Kebbi'), ('KO', 'Kogi'),
  ('KW', 'Kwara'), ('LA', 'Lagos'), ('NA', 'Nasarawa'), ('NI', 'Niger'),
  ('OG', 'Ogun'), ('ON', 'Ondo'), ('OS', 'Osun'), ('OY', 'Oyo'),
  ('PL', 'Plateau'), ('RI', 'Rivers'), ('SO', 'Sokoto'), ('TA', 'Taraba'),
  ('YO', 'Yobe'), ('ZA', 'Zamfara');

-- one '|'-separated list per state, expanded below
insert into public.ng_lgas (id, state_code, name)
select md5('ng_lga:' || s.code || ':' || l.name)::uuid, s.code, l.name
  from (values
    ('AB', 'Aba North|Aba South|Arochukwu|Bende|Ikwuano|Isiala Ngwa North|Isiala Ngwa South|Isuikwuato|Obi Ngwa|Ohafia|Osisioma|Ugwunagbo|Ukwa East|Ukwa West|Umuahia North|Umuahia South|Umu Nneochi'),
    ('AD', 'Demsa|Fufure|Ganye|Guyuk|Gombi|Girei|Hong|Jada|Lamurde|Madagali|Maiha|Mayo Belwa|Michika|Mubi North|Mubi South|Numan|Shelleng|Song|Toungo|Yola North|Yola South'),
    ('AK', 'Abak|Eastern Obolo|Eket|Esit Eket|Essien Udim|Etim Ekpo|Etinan|Ibeno|Ibesikpo Asutan|Ibiono-Ibom|Ika|Ikono|Ikot Abasi|Ikot Ekpene|Ini|Itu|Mbo|Mkpat-Enin|Nsit-Atai|Nsit-Ibom|Nsit-Ubium|Obot Akara|Okobo|Onna|Oron|Oruk Anam|Udung-Uko|Ukanafun|Uruan|Urue-Offong/Oruko|Uyo'),
    ('AN', 'Aguata|Anambra East|Anambra West|Anaocha|Awka North|Awka South|Ayamelum|Dunukofia|Ekwusigo|Idemili North|Idemili South|Ihiala|Njikoka|Nnewi North|Nnewi South|Ogbaru|Onitsha North|Onitsha South|Orumba North|Orumba South|Oyi'),
    ('BA', 'Alkaleri|Bauchi|Bogoro|Dambam|Darazo|Dass|Gamawa|Ganjuwa|Giade|Itas/Gadau|Jama''are|Katagum|Kirfi|Misau|Ningi|Shira|Tafawa Balewa|Toro|Warji|Zaki'),
    ('BY', 'Brass|Ekeremor|Kolokuma/Opokuma|Nembe|Ogbia|Sagbama|Southern Ijaw|Yenagoa'),
    ('BE', 'Ado|Agatu|Apa|Buruku|Gboko|Guma|Gwer East|Gwer West|Katsina-Ala|Konshisha|Kwande|Logo|Makurdi|Obi|Ogbadibo|Ohimini|Oju|Okpokwu|Oturkpo|Tarka|Ukum|Ushongo|Vandeikya'),
    ('BO', 'Abadam|Askira/Uba|Bama|Bayo|Biu|Chibok|Damboa|Dikwa|Gubio|Guzamala|Gwoza|Hawul|Jere|Kaga|Kala/Balge|Konduga|Kukawa|Kwaya Kusar|Mafa|Magumeri|Maiduguri|Marte|Mobbar|Monguno|Ngala|Nganzai|Shani'),
    ('CR', 'Abi|Akamkpa|Akpabuyo|Bakassi|Bekwarra|Biase|Boki|Calabar Municipal|Calabar South|Etung|Ikom|Obanliku|Obubra|Obudu|Odukpani|Ogoja|Yakurr|Yala'),
    ('DE', 'Aniocha North|Aniocha South|Bomadi|Burutu|Ethiope East|Ethiope West|Ika North East|Ika South|Isoko North|Isoko South|Ndokwa East|Ndokwa West|Okpe|Oshimili North|Oshimili South|Patani|Sapele|Udu|Ughelli North|Ughelli South|Ukwuani|Uvwie|Warri North|Warri South|Warri South West'),
    ('EB', 'Abakaliki|Afikpo North|Afikpo South|Ebonyi|Ezza North|Ezza South|Ikwo|Ishielu|Ivo|Izzi|Ohaozara|Ohaukwu|Onicha'),
    ('ED', 'Akoko-Edo|Egor|Esan Central|Esan North-East|Esan South-East|Esan West|Etsako Central|Etsako East|Etsako West|Igueben|Ikpoba Okha|Oredo|Orhionmwon|Ovia North-East|Ovia South-West|Owan East|Owan West|Uhunmwonde'),
    ('EK', 'Ado Ekiti|Efon|Ekiti East|Ekiti South-West|Ekiti West|Emure|Gbonyin|Ido Osi|Ijero|Ikere|Ikole|Ilejemeje|Irepodun/Ifelodun|Ise/Orun|Moba|Oye'),
    ('EN', 'Aninri|Awgu|Enugu East|Enugu North|Enugu South|Ezeagu|Igbo Etiti|Igbo Eze North|Igbo Eze South|Isi Uzo|Nkanu East|Nkanu West|Nsukka|Oji River|Udenu|Udi|Uzo Uwani'),
    ('FC', 'Abaji|Bwari|Gwagwalada|Kuje|Kwali|Abuja Municipal'),
    ('GO', 'Akko|Balanga|Billiri|Dukku|Funakaye|Gombe|Kaltungo|Kwami|Nafada|Shongom|Yamaltu/Deba'),
    ('IM', 'Aboh Mbaise|Ahiazu Mbaise|Ehime Mbano|Ezinihitte|Ideato North|Ideato South|Ihitte/Uboma|Ikeduru|Isiala Mbano|Isu|Mbaitoli|Ngor Okpala|Njaba|Nkwerre|Nwangele|Obowo|Oguta|Ohaji/Egbema|Okigwe|Orlu|Orsu|Oru East|Oru West|Owerri Municipal|Owerri North|Owerri West|Onuimo'),
    ('JI', 'Auyo|Babura|Birniwa|Birnin Kudu|Buji|Dutse|Gagarawa|Garki|Gumel|Guri|Gwaram|Gwiwa|Hadejia|Jahun|Kafin Hausa|Kaugama|Kazaure|Kiri Kasama|Kiyawa|Maigatari|Malam Madori|Miga|Ringim|Roni|Sule Tankarkar|Taura|Yankwashi'),
    ('KD', 'Birnin Gwari|Chikun|Giwa|Igabi|Ikara|Jaba|Jema''a|Kachia|Kaduna North|Kaduna South|Kagarko|Kajuru|Kaura|Kauru|Kubau|Kudan|Lere|Makarfi|Sabon Gari|Sanga|Soba|Zangon Kataf|Zaria'),
    ('KN', 'Ajingi|Albasu|Bagwai|Bebeji|Bichi|Bunkure|Dala|Dambatta|Dawakin Kudu|Dawakin Tofa|Doguwa|Fagge|Gabasawa|Garko|Garun Mallam|Gaya|Gezawa|Gwale|Gwarzo|Kabo|Kano Municipal|Karaye|Kibiya|Kiru|Kumbotso|Kunchi|Kura|Madobi|Makoda|Minjibir|Nasarawa|Rano|Rimin Gado|Rogo|Shanono|Sumaila|Takai|Tarauni|Tofa|Tsanyawa|Tudun Wada|Ungogo|Warawa|Wudil'),
    ('KT', 'Bakori|Batagarawa|Batsari|Baure|Bindawa|Charanchi|Dandume|Danja|Dan Musa|Daura|Dutsi|Dutsin-Ma|Faskari|Funtua|Ingawa|Jibia|Kafur|Kaita|Kankara|Kankia|Katsina|Kurfi|Kusada|Mai''Adua|Malumfashi|Mani|Mashi|Matazu|Musawa|Rimi|Sabuwa|Safana|Sandamu|Zango'),
    ('KE', 'Aleiro|Arewa Dandi|Argungu|Augie|Bagudo|Birnin Kebbi|Bunza|Dandi|Fakai|Gwandu|Jega|Kalgo|Koko/Besse|Maiyama|Ngaski|Sakaba|Shanga|Suru|Danko/Wasagu|Yauri|Zuru'),
    ('KO', 'Adavi|Ajaokuta|Ankpa|Bassa|Dekina|Ibaji|Idah|Igalamela-Odolu|Ijumu|Kabba/Bunu|Kogi|Lokoja|Mopa-Muro|Ofu|Ogori/Magongo|Okehi|Okene|Olamaboro|Omala|Yagba East|Yagba West'),
    ('KW', 'Asa|Baruten|Edu|Ekiti|Ifelodun|Ilorin East|Ilorin South|Ilorin West|Irepodun|Isin|Kaiama|Moro|Offa|Oke Ero|Oyun|Pategi'),
    ('LA', 'Agege|Ajeromi-Ifelodun|Alimosho|Amuwo-Odofin|Apapa|Badagry|Epe|Eti-Osa|Ibeju-Lekki|Ifako-Ijaiye|Ikeja|Ikorodu|Kosofe|Lagos Island|Lagos Mainland|Mushin|Ojo|Oshodi-Isolo|Shomolu|Surulere'),
    ('NA', 'Akwanga|Awe|Doma|Karu|Keana|Keffi|Kokona|Lafia|Nasarawa|Nasarawa Eggon|Obi|Toto|Wamba'),
    ('NI', 'Agaie|Agwara|Bida|Borgu|Bosso|Chanchaga|Edati|Gbako|Gurara|Katcha|Kontagora|Lapai|Lavun|Magama|Mariga|Mashegu|Mokwa|Munya|Paikoro|Rafi|Rijau|Shiroro|Suleja|Tafa|Wushishi'),
    ('OG', 'Abeokuta North|Abeokuta South|Ado-Odo/Ota|Ewekoro|Ifo|Ijebu East|Ijebu North|Ijebu North East|Ijebu Ode|Ikenne|Imeko Afon|Ipokia|Obafemi Owode|Odeda|Odogbolu|Ogun Waterside|Remo North|Shagamu|Yewa North|Yewa South'),
    ('ON', 'Akoko North-East|Akoko North-West|Akoko South-East|Akoko South-West|Akure North|Akure South|Ese Odo|Idanre|Ifedore|Ilaje|Ile Oluji/Okeigbo|Irele|Odigbo|Okitipupa|Ondo East|Ondo West|Ose|Owo'),
    ('OS', 'Atakunmosa East|Atakunmosa West|Aiyedaade|Aiyedire|Boluwaduro|Boripe|Ede North|Ede South|Egbedore|Ejigbo|Ife Central|Ife East|Ife North|Ife South|Ifedayo|Ifelodun|Ila|Ilesa East|Ilesa West|Irepodun|Irewole|Isokan|Iwo|Obokun|Odo Otin|Ola Oluwa|Olorunda|Oriade|Orolu|Osogbo'),
    ('OY', 'Afijio|Akinyele|Atiba|Atisbo|Egbeda|Ibadan North|Ibadan North-East|Ibadan North-West|Ibadan South-East|Ibadan South-West|Ibarapa Central|Ibarapa East|Ibarapa North|Ido|Irepo|Iseyin|Itesiwaju|Iwajowa|Kajola|Lagelu|Ogbomosho North|Ogbomosho South|Ogo Oluwa|Olorunsogo|Oluyole|Ona Ara|Orelope|Ori Ire|Oyo East|Oyo West|Saki East|Saki West|Surulere'),
    ('PL', 'Barkin Ladi|Bassa|Bokkos|Jos East|Jos North|Jos South|Kanam|Kanke|Langtang North|Langtang South|Mangu|Mikang|Pankshin|Qua''an Pan|Riyom|Shendam|Wase'),
    ('RI', 'Abua/Odual|Ahoada East|Ahoada West|Akuku-Toru|Andoni|Asari-Toru|Bonny|Degema|Eleme|Emohua|Etche|Gokana|Ikwerre|Khana|Obio/Akpor|Ogba/Egbema/Ndoni|Ogu/Bolo|Okrika|Omuma|Opobo/Nkoro|Oyigbo|Port Harcourt|Tai'),
    ('SO', 'Binji|Bodinga|Dange Shuni|Gada|Goronyo|Gudu|Gwadabawa|Illela|Isa|Kebbe|Kware|Rabah|Sabon Birni|Shagari|Silame|Sokoto North|Sokoto South|Tambuwal|Tangaza|Tureta|Wamakko|Wurno|Yabo'),
    ('TA', 'Ardo Kola|Bali|Donga|Gashaka|Gassol|Ibi|Jalingo|Karim Lamido|Kurmi|Lau|Sardauna|Takum|Ussa|Wukari|Yorro|Zing'),
    ('YO', 'Bade|Bursari|Damaturu|Fika|Fune|Geidam|Gujba|Gulani|Jakusko|Karasuwa|Machina|Nangere|Nguru|Potiskum|Tarmuwa|Yunusari|Yusufari'),
    ('ZA', 'Anka|Bakura|Birnin Magaji/Kiyaw|Bukkuyum|Bungudu|Gummi|Gusau|Kaura Namoda|Maradun|Maru|Shinkafi|Talata Mafara|Tsafe|Zurmi')
  ) as s (code, names)
 cross join lateral unnest(string_to_array(s.names, '|')) as l (name);

-- Completeness check: INEC's count per state, 774 in all.
do $$
declare
  v_expected constant jsonb := '{"AB":17,"AD":21,"AK":31,"AN":21,"BA":20,"BY":8,"BE":23,"BO":27,"CR":18,
    "DE":25,"EB":13,"ED":18,"EK":16,"EN":17,"FC":6,"GO":11,"IM":27,"JI":27,"KD":23,"KN":44,"KT":34,
    "KE":21,"KO":21,"KW":16,"LA":20,"NA":13,"NI":25,"OG":20,"ON":18,"OS":30,"OY":33,"PL":17,"RI":23,
    "SO":23,"TA":16,"YO":17,"ZA":14}';
  v_row record;
begin
  if (select count(*) from public.ng_states) <> 37 then
    raise exception 'ng_states: expected 37 states, found %', (select count(*) from public.ng_states);
  end if;
  if (select count(*) from public.ng_lgas) <> 774 then
    raise exception 'ng_lgas: expected 774 LGAs, found %', (select count(*) from public.ng_lgas);
  end if;
  for v_row in
    select s.code, count(l.id)::int as n
      from public.ng_states s left join public.ng_lgas l on l.state_code = s.code
     group by s.code
  loop
    if v_row.n <> (v_expected ->> v_row.code)::int then
      raise exception 'ng_lgas: state % expected % LGAs, found %',
        v_row.code, v_expected ->> v_row.code, v_row.n;
    end if;
  end loop;
end $$;

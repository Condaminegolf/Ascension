
-- Your Path Friends v2. Run after 20261028_nextform_friends.sql.
-- Users remain discoverable only when enabled, with no health or workout detail exposed.
CREATE OR REPLACE FUNCTION public.nf_social_search(p_query text, p_limit integer DEFAULT 20)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE u uuid := auth.uid(); q text:=lower(trim(coalesce(p_query,'')));
BEGIN
 IF u IS NULL THEN RAISE EXCEPTION 'Sign in first'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.nf_social_profiles WHERE user_id=u AND enabled) THEN
 RAISE EXCEPTION 'Enable your Friends profile before searching'; END IF;
 IF char_length(q)<2 THEN RETURN '[]'::jsonb; END IF;
 RETURN (SELECT coalesce(jsonb_agg(jsonb_build_object(
 'handle',p.handle,'display_name',p.display_name,
 'status',coalesce(f.status,'none'),
 'direction',CASE WHEN f.requested_by=u THEN 'outgoing' WHEN f.requested_by IS NOT NULL THEN 'incoming' ELSE NULL END
 ) ORDER BY p.handle),'[]'::jsonb)
 FROM (SELECT p.user_id,p.handle,p.display_name FROM public.nf_social_profiles p
       WHERE p.enabled AND p.user_id<>u AND (p.handle LIKE '%'||replace(replace(q,'%',''),'_','')||'%' OR lower(p.display_name) LIKE '%'||replace(replace(q,'%',''),'_','')||'%')
       ORDER BY CASE WHEN p.handle=q THEN 0 ELSE 1 END,p.handle
       LIMIT least(greatest(coalesce(p_limit,20),1),30)) p
 LEFT JOIN public.nf_social_friendships f ON f.member_low=least(u,p.user_id) AND f.member_high=greatest(u,p.user_id));
END $$;

-- Monday 00:00 to following Monday 00:00 Brisbane time, for every participant.
-- Each category is separately capped so high-volume workouts cannot dominate.
-- Consistency: 35 pts (5 or more active days); Strength: 25 (50 logged sets);
-- Cardio: 25 (150 logged minutes); Variety: 15 (3 modes: strength/run/cycle/walk).
CREATE OR REPLACE FUNCTION public.nf_social_leaderboard()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE
 u uuid:=auth.uid();
 monday date:=date_trunc('week',timezone('Australia/Brisbane',now()))::date;
 ending date:=monday+7;
 r record;
 w jsonb; c jsonb; d jsonb;
 dt text; kind text;
 active_dates text[];
 sessions integer; sets_n integer; cardio_minutes numeric; mins numeric;
 run_km numeric; cycle_km numeric; modes text[];
 consistency_pts integer; strength_pts integer; cardio_pts integer; variety_pts integer;
 rows jsonb:='[]'::jsonb;
BEGIN
 IF u IS NULL THEN RAISE EXCEPTION 'Sign in first'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.nf_social_profiles WHERE user_id=u AND enabled) THEN RETURN '[]'::jsonb; END IF;
 FOR r IN
 SELECT p.user_id,p.handle,p.display_name,coalesce(s.save_data,'{}'::jsonb) payload
 FROM public.nf_social_profiles p
 LEFT JOIN public.ascension_saves s ON s.user_id=p.user_id
 WHERE p.enabled AND (p.user_id=u OR EXISTS (
 SELECT 1 FROM public.nf_social_friendships f WHERE f.status='accepted'
 AND f.member_low=least(u,p.user_id) AND f.member_high=greatest(u,p.user_id)))
 LOOP
  active_dates:=ARRAY[]::text[];modes:=ARRAY[]::text[];sessions:=0;sets_n:=0;
  cardio_minutes:=0;run_km:=0;cycle_km:=0;
  FOR w IN SELECT value FROM jsonb_array_elements(
   CASE WHEN jsonb_typeof(r.payload->'workouts')='array' THEN r.payload->'workouts' ELSE '[]'::jsonb END)
  LOOP
   dt:=w->>'date';
   IF dt IS NULL OR dt !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' OR dt<monday::text OR dt>=ending::text THEN CONTINUE; END IF;
   IF jsonb_typeof(w->'sets')<>'array' OR jsonb_array_length(w->'sets')=0 THEN CONTINUE; END IF;
   sessions:=sessions+1;
   IF NOT(dt=ANY(active_dates)) THEN active_dates:=array_append(active_dates,dt); END IF;
   IF NOT('strength'=ANY(modes)) THEN modes:=array_append(modes,'strength'); END IF;
   sets_n:=sets_n+least(jsonb_array_length(w->'sets'),150);
  END LOOP;
  FOR c IN SELECT value FROM jsonb_array_elements(
   CASE WHEN jsonb_typeof(r.payload->'cardio')='array' THEN r.payload->'cardio' ELSE '[]'::jsonb END)
  LOOP
   dt:=c->>'date';
   IF dt IS NULL OR dt !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' OR dt<monday::text OR dt>=ending::text THEN CONTINUE; END IF;
   kind:=lower(coalesce(c->>'type',''));
   IF kind NOT IN ('run','running','cycle','cycling','bike','ride','walk','walking') THEN CONTINUE; END IF;
   IF (c->>'minutes') !~ '^[0-9]{1,4}([.][0-9]{1,2})?$' THEN CONTINUE; END IF;
   mins:=(c->>'minutes')::numeric;
   IF mins<=0 OR mins>1440 THEN CONTINUE; END IF;
   sessions:=sessions+1;cardio_minutes:=cardio_minutes+mins;
   IF NOT(dt=ANY(active_dates)) THEN active_dates:=array_append(active_dates,dt); END IF;
   kind:=CASE WHEN kind IN ('running','run') THEN 'run' WHEN kind IN ('cycle','cycling','bike','ride') THEN 'cycle' ELSE 'walk' END;
   IF NOT(kind=ANY(modes)) THEN modes:=array_append(modes,kind); END IF;
   IF (c->>'distance') ~ '^[0-9]{1,5}([.][0-9]{1,3})?$' AND (c->>'distance')::numeric<=1000 THEN
    IF kind='run' THEN run_km:=run_km+(c->>'distance')::numeric;
    ELSIF kind='cycle' THEN cycle_km:=cycle_km+(c->>'distance')::numeric; END IF;
   END IF;
  END LOOP;
  consistency_pts:=least(cardinality(active_dates),5)*7;
  strength_pts:=least(25,floor(sets_n::numeric/2)::integer);
  cardio_pts:=least(25,floor(cardio_minutes/6)::integer);
  variety_pts:=least(cardinality(modes),3)*5;
  rows:=rows||jsonb_build_array(jsonb_build_object(
   'handle',r.handle,'display_name',r.display_name,'self',r.user_id=u,
   'week_start',monday,'active_days',cardinality(active_dates),
   'sessions',sessions,'strength_sets',sets_n,'cardio_minutes',round(cardio_minutes,0),
   'run_km',round(run_km,1),'cycle_km',round(cycle_km,1),
   'score',consistency_pts+strength_pts+cardio_pts+variety_pts,
   'consistency_score',consistency_pts,'strength_score',strength_pts,
   'cardio_score',cardio_pts,'variety_score',variety_pts
  ));
 END LOOP;
 RETURN (SELECT coalesce(jsonb_agg(v ORDER BY (v->>'score')::integer DESC,
 (v->>'active_days')::integer DESC,v->>'handle'),'[]'::jsonb)
 FROM jsonb_array_elements(rows) v);
END $$;
REVOKE ALL ON FUNCTION public.nf_social_search(text,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.nf_social_search(text,integer) TO authenticated;

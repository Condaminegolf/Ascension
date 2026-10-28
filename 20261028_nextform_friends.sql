-- NEXTFORM Friends (2026-10). Additive schema: does not change ascension_saves,
-- existing auth users, integrations, or workout data.
-- Supabase SQL editor: execute once, or use project migration.
CREATE TABLE IF NOT EXISTS public.nf_social_profiles (
 user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
 handle text NOT NULL UNIQUE CHECK (handle ~ '^[a-z0-9_]{3,20}$'),
 display_name text NOT NULL CHECK (char_length(display_name) BETWEEN 1 AND 48),
 enabled boolean NOT NULL DEFAULT false,
 created_at timestamptz NOT NULL DEFAULT now(),
 updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.nf_social_friendships (
 member_low uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
 member_high uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
 requested_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
 status text NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','accepted')),
 created_at timestamptz NOT NULL DEFAULT now(),
 updated_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY (member_low, member_high),
 CHECK (member_low < member_high),
 CHECK (requested_by = member_low OR requested_by = member_high)
);
CREATE INDEX IF NOT EXISTS nf_social_friendships_high_idx ON public.nf_social_friendships(member_high, status);
ALTER TABLE public.nf_social_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.nf_social_friendships ENABLE ROW LEVEL SECURITY;
-- Clients can only select their own social profile; other users are exposed only via
-- scoped security-definer RPCs, and only if opted in. No direct table writes.
DROP POLICY IF EXISTS "NEXTFORM social profile owner read" ON public.nf_social_profiles;
CREATE POLICY "NEXTFORM social profile owner read" ON public.nf_social_profiles
 FOR SELECT TO authenticated USING (user_id = (SELECT auth.uid()));
DROP POLICY IF EXISTS "NEXTFORM friendships members read" ON public.nf_social_friendships;
CREATE POLICY "NEXTFORM friendships members read" ON public.nf_social_friendships
 FOR SELECT TO authenticated USING (member_low = (SELECT auth.uid()) OR member_high = (SELECT auth.uid()));
REVOKE ALL ON TABLE public.nf_social_profiles FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.nf_social_friendships FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.nf_social_profiles, public.nf_social_friendships TO authenticated;

CREATE OR REPLACE FUNCTION public.nf_social_set_profile(p_handle text, p_name text, p_enabled boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE u uuid := auth.uid(); h text := lower(trim(coalesce(p_handle,''))); n text := trim(coalesce(p_name,''));
BEGIN
 IF u IS NULL THEN RAISE EXCEPTION 'Sign in to manage your Friends profile'; END IF;
 IF h !~ '^[a-z0-9_]{3,20}$' THEN RAISE EXCEPTION 'Handle must be 3–20 lowercase letters, numbers or underscores'; END IF;
 IF length(n) NOT BETWEEN 1 AND 48 THEN RAISE EXCEPTION 'Display name must be 1–48 characters'; END IF;
 INSERT INTO public.nf_social_profiles(user_id,handle,display_name,enabled)
 VALUES(u,h,n,coalesce(p_enabled,false))
 ON CONFLICT(user_id) DO UPDATE SET handle=excluded.handle,display_name=excluded.display_name,
 enabled=excluded.enabled,updated_at=now();
 RETURN jsonb_build_object('handle',h,'display_name',n,'enabled',coalesce(p_enabled,false));
END $$;

CREATE OR REPLACE FUNCTION public.nf_social_send_request(p_handle text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE u uuid := auth.uid(); other uuid; a uuid; b uuid;
BEGIN
 IF u IS NULL THEN RAISE EXCEPTION 'Sign in first'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.nf_social_profiles WHERE user_id=u AND enabled) THEN
  RAISE EXCEPTION 'Enable your Friends profile first'; END IF;
 SELECT user_id INTO other FROM public.nf_social_profiles
 WHERE handle=lower(trim(coalesce(p_handle,''))) AND enabled;
 IF other IS NULL THEN RAISE EXCEPTION 'No opted-in athlete has that exact handle'; END IF;
 IF other=u THEN RAISE EXCEPTION 'You cannot friend yourself'; END IF;
 a:=least(u,other); b:=greatest(u,other);
 IF EXISTS(SELECT 1 FROM public.nf_social_friendships WHERE member_low=a AND member_high=b) THEN
  RAISE EXCEPTION 'A request or friendship already exists'; END IF;
 INSERT INTO public.nf_social_friendships(member_low,member_high,requested_by,status)
 VALUES(a,b,u,'pending');
 RETURN 'Request sent';
END $$;

CREATE OR REPLACE FUNCTION public.nf_social_friend_action(p_handle text,p_action text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE u uuid:=auth.uid(); other uuid; relation public.nf_social_friendships%ROWTYPE; action text:=lower(trim(coalesce(p_action,'')));
BEGIN
 IF u IS NULL THEN RAISE EXCEPTION 'Sign in first'; END IF;
 SELECT user_id INTO other FROM public.nf_social_profiles WHERE handle=lower(trim(coalesce(p_handle,'')));
 IF other IS NULL THEN RAISE EXCEPTION 'Athlete not found'; END IF;
 SELECT * INTO relation FROM public.nf_social_friendships f
 WHERE f.member_low=least(u,other) AND f.member_high=greatest(u,other) FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'No matching request or friendship'; END IF;
 IF action='accept' AND relation.status='pending' AND relation.requested_by<>u THEN
  UPDATE public.nf_social_friendships SET status='accepted',updated_at=now()
  WHERE member_low=relation.member_low AND member_high=relation.member_high;
 ELSIF action='decline' AND relation.status='pending' AND relation.requested_by<>u THEN
  DELETE FROM public.nf_social_friendships WHERE member_low=relation.member_low AND member_high=relation.member_high;
 ELSIF action='cancel' AND relation.status='pending' AND relation.requested_by=u THEN
  DELETE FROM public.nf_social_friendships WHERE member_low=relation.member_low AND member_high=relation.member_high;
 ELSIF action='remove' AND relation.status='accepted' THEN
  DELETE FROM public.nf_social_friendships WHERE member_low=relation.member_low AND member_high=relation.member_high;
 ELSE RAISE EXCEPTION 'Action not permitted for this relationship'; END IF;
 RETURN action;
END $$;

CREATE OR REPLACE FUNCTION public.nf_social_state()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE u uuid:=auth.uid(); own jsonb; relationships jsonb;
BEGIN
 IF u IS NULL THEN RAISE EXCEPTION 'Sign in first'; END IF;
 SELECT jsonb_build_object('handle',handle,'display_name',display_name,'enabled',enabled)
 INTO own FROM public.nf_social_profiles WHERE user_id=u;
 SELECT coalesce(jsonb_agg(jsonb_build_object('handle',p.handle,'display_name',p.display_name,
    'enabled',p.enabled,'status',f.status,
    'direction',CASE WHEN f.requested_by=u THEN 'outgoing' ELSE 'incoming' END)
    ORDER BY f.created_at DESC),'[]'::jsonb) INTO relationships
 FROM public.nf_social_friendships f
 JOIN public.nf_social_profiles p ON p.user_id=CASE WHEN f.member_low=u THEN f.member_high ELSE f.member_low END
 WHERE f.member_low=u OR f.member_high=u;
 RETURN jsonb_build_object('profile',own,'relationships',relationships);
END $$;

-- Returns only aggregate scores of you and accepted, opted-in friends.
-- Original saved workouts/health information never leaves the database.
-- Leaderboards are friendly/self-reported, not anti-cheat competitive results.
CREATE OR REPLACE FUNCTION public.nf_social_leaderboard()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE u uuid:=auth.uid(); week_start date:=date_trunc('week', timezone('Australia/Brisbane',now()))::date;
 rec record; work jsonb; activity jsonb; data jsonb; t text; active_dates text[]; training integer; sets_count integer; cardio_count integer;
 run_km numeric; ride_km numeric; distance_text text; result jsonb:='[]'::jsonb;
BEGIN
 IF u IS NULL THEN RAISE EXCEPTION 'Sign in first'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.nf_social_profiles WHERE user_id=u AND enabled) THEN
  RETURN '[]'::jsonb; END IF;
 FOR rec IN
 SELECT p.user_id,p.handle,p.display_name,s.save_data
 FROM public.nf_social_profiles p
 LEFT JOIN public.ascension_saves s ON s.user_id=p.user_id
 WHERE p.enabled AND (p.user_id=u OR EXISTS (
   SELECT 1 FROM public.nf_social_friendships f WHERE f.status='accepted'
    AND f.member_low=least(u,p.user_id) AND f.member_high=greatest(u,p.user_id)))
 LOOP
  data:=coalesce(rec.save_data,'{}'::jsonb);
  active_dates:=ARRAY[]::text[]; training:=0;sets_count:=0;cardio_count:=0;run_km:=0;ride_km:=0;
  FOR work IN SELECT value FROM jsonb_array_elements(
   CASE WHEN jsonb_typeof(data->'workouts')='array' THEN data->'workouts' ELSE '[]'::jsonb END)
  LOOP
   t:=work->>'date';
   IF t IS NULL OR t !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' OR t<week_start::text OR t>=(week_start+7)::text THEN CONTINUE; END IF;
   training:=training+1;
   IF array_position(active_dates,t) IS NULL THEN active_dates:=array_append(active_dates,t); END IF;
   IF jsonb_typeof(work->'sets')='array' THEN
    sets_count:=sets_count+least(jsonb_array_length(work->'sets'),1000); END IF;
  END LOOP;
  FOR activity IN SELECT value FROM jsonb_array_elements(
    CASE WHEN jsonb_typeof(data->'cardio')='array' THEN data->'cardio' ELSE '[]'::jsonb END)
  LOOP
   t:=activity->>'date';
   IF t IS NULL OR t !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' OR t<week_start::text OR t>=(week_start+7)::text THEN CONTINUE; END IF;
   cardio_count:=cardio_count+1;
   IF array_position(active_dates,t) IS NULL THEN active_dates:=array_append(active_dates,t); END IF;
   distance_text:=activity->>'distance';
   IF distance_text ~ '^[0-9]{1,5}([.][0-9]{1,3})?$' THEN
    IF distance_text::numeric BETWEEN 0 AND 1000 THEN
    IF activity->>'type'='run' THEN run_km:=run_km+distance_text::numeric;
    ELSIF activity->>'type'='cycle' THEN ride_km:=ride_km+distance_text::numeric; END IF;
    END IF;
   END IF;
  END LOOP;
  result:=result||jsonb_build_array(jsonb_build_object(
    'handle',rec.handle,'display_name',rec.display_name,'self',rec.user_id=u,
    'week_start',week_start,'active_days',cardinality(active_dates),
    'sessions',training+cardio_count,'strength_sets',sets_count,
    'run_km',round(run_km,1),'cycle_km',round(ride_km,1)
  ));
 END LOOP;
 RETURN result;
END $$;

-- Friends' character build is limited to type, selected title, and worn item ranks.
CREATE OR REPLACE FUNCTION public.nf_social_view_build(p_handle text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE u uuid:=auth.uid(); target uuid; data jsonb; eq jsonb; ct text; title text;
BEGIN
 IF u IS NULL THEN RAISE EXCEPTION 'Sign in first'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.nf_social_profiles WHERE user_id=u AND enabled) THEN
  RAISE EXCEPTION 'Enable your Friends profile first'; END IF;
 SELECT user_id INTO target FROM public.nf_social_profiles
 WHERE handle=lower(trim(coalesce(p_handle,''))) AND enabled;
 IF target IS NULL THEN RAISE EXCEPTION 'Friend is not currently sharing'; END IF;
 IF target<>u AND NOT EXISTS(SELECT 1 FROM public.nf_social_friendships f WHERE f.status='accepted'
    AND f.member_low=least(u,target) AND f.member_high=greatest(u,target)) THEN
  RAISE EXCEPTION 'Only accepted friends can view builds'; END IF;
 SELECT save_data INTO data FROM public.ascension_saves WHERE user_id=target;
 data:=coalesce(data,'{}'::jsonb);
 ct:=CASE WHEN data->>'nfCharacterType'='female' THEN 'female' ELSE 'male' END;
 eq:=CASE WHEN ct='female' THEN data->'nfFemaleEquipment' ELSE data->'nfMaleEquipment' END;
 eq:=CASE WHEN jsonb_typeof(eq)='object' THEN eq ELSE '{}'::jsonb END;
 title:=data->'nfTitleRewardsV1'->>'equipped';
 RETURN jsonb_build_object('character',ct,'title',left(coalesce(title,''),48),
   'equipment',jsonb_build_object(
    'top',CASE WHEN eq->>'top' IN ('f','e','d','c','b','a','s') THEN eq->>'top' END,
    'shorts',CASE WHEN eq->>'shorts' IN ('f','e','d','c','b','a','s') THEN eq->>'shorts' END,
    'shoes',CASE WHEN eq->>'shoes' IN ('f','e','d','c','b','a','s') THEN eq->>'shoes' END,
    'watch',CASE WHEN eq->>'watch' IN ('f','e','d','c','b','a','s') THEN eq->>'watch' END,
    'sunglasses',CASE WHEN eq->>'sunglasses' IN ('f','e','d','c','b','a','s') THEN eq->>'sunglasses' END
   ));
END $$;

REVOKE ALL ON FUNCTION public.nf_social_set_profile(text,text,boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.nf_social_send_request(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.nf_social_friend_action(text,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.nf_social_state() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.nf_social_leaderboard() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.nf_social_view_build(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.nf_social_set_profile(text,text,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.nf_social_send_request(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.nf_social_friend_action(text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.nf_social_state() TO authenticated;
GRANT EXECUTE ON FUNCTION public.nf_social_leaderboard() TO authenticated;
GRANT EXECUTE ON FUNCTION public.nf_social_view_build(text) TO authenticated;

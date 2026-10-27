-- Apply after 001_security_hardening.sql. No production execution is automatic.
BEGIN;
ALTER TABLE public.videos ADD COLUMN IF NOT EXISTS file_path text;
ALTER TABLE public.videos ALTER COLUMN status SET DEFAULT 'pending';
ALTER TABLE public.shop_items ADD COLUMN IF NOT EXISTS file_path text;
ALTER TABLE public.shop_items ADD COLUMN IF NOT EXISTS review_status text NOT NULL DEFAULT 'pending';
ALTER TABLE public.shop_items ALTER COLUMN active SET DEFAULT false;
ALTER TABLE public.follows ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'accepted';
CREATE TABLE IF NOT EXISTS public.video_likes(user_id text REFERENCES public.profiles(id),video_id uuid REFERENCES public.videos(id),created_at timestamptz DEFAULT now(),PRIMARY KEY(user_id,video_id));
CREATE TABLE IF NOT EXISTS public.video_saves(user_id text REFERENCES public.profiles(id),video_id uuid REFERENCES public.videos(id),created_at timestamptz DEFAULT now(),PRIMARY KEY(user_id,video_id));
CREATE TABLE IF NOT EXISTS public.comments(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),video_id uuid REFERENCES public.videos(id),user_id text REFERENCES public.profiles(id),body text NOT NULL CHECK(length(body) BETWEEN 1 AND 2000),created_at timestamptz DEFAULT now());
CREATE TABLE IF NOT EXISTS public.notifications(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),user_id text REFERENCES public.profiles(id),body text NOT NULL,read_at timestamptz,created_at timestamptz DEFAULT now());
CREATE TABLE IF NOT EXISTS public.direct_messages(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),sender_id text REFERENCES public.profiles(id),recipient_id text REFERENCES public.profiles(id),body text NOT NULL CHECK(length(body) BETWEEN 1 AND 2000),read_at timestamptz,created_at timestamptz DEFAULT now());
CREATE TABLE IF NOT EXISTS public.user_blocks(user_id text REFERENCES public.profiles(id),blocked_id text REFERENCES public.profiles(id),PRIMARY KEY(user_id,blocked_id));
CREATE TABLE IF NOT EXISTS public.account_deletion_requests(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),user_id text UNIQUE REFERENCES public.profiles(id),status text NOT NULL DEFAULT 'pending',created_at timestamptz DEFAULT now(),completed_at timestamptz);
CREATE TABLE IF NOT EXISTS public.admin_audit_log(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),actor_id text REFERENCES public.profiles(id),action text NOT NULL,target_id text NOT NULL,note text NOT NULL,created_at timestamptz DEFAULT now());
CREATE TABLE IF NOT EXISTS public.app_rate_limits(actor text,action text,window_start timestamptz,hits integer NOT NULL,PRIMARY KEY(actor,action));
CREATE INDEX IF NOT EXISTS messages_recipient_time ON public.direct_messages(recipient_id,created_at DESC);
CREATE INDEX IF NOT EXISTS messages_sender_time ON public.direct_messages(sender_id,created_at DESC);
CREATE INDEX IF NOT EXISTS notifications_user_time ON public.notifications(user_id,created_at DESC);
CREATE INDEX IF NOT EXISTS comments_video_time ON public.comments(video_id,created_at);
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['video_likes','video_saves','comments','notifications','direct_messages','user_blocks','account_deletion_requests','admin_audit_log','app_rate_limits'] LOOP
  EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',t);
  EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC,anon,authenticated',t);
 END LOOP;
END $$;
CREATE OR REPLACE FUNCTION public.require_member() RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE actor text := (SELECT auth.uid())::text;
BEGIN
 IF actor IS NULL OR NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=actor AND NOT suspended AND role<>'deleted') THEN RAISE EXCEPTION 'Sign in with an active account' USING ERRCODE='42501'; END IF;
 RETURN actor;
END $$;
CREATE OR REPLACE FUNCTION public.require_admin() RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE actor text := public.require_member();
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=actor AND role='admin') THEN RAISE EXCEPTION 'Administrator access required' USING ERRCODE='42501'; END IF; RETURN actor;
END $$;
CREATE OR REPLACE FUNCTION public.enforce_rate_limit(actor text,operation text,maximum integer DEFAULT 30) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE used integer;
BEGIN
 INSERT INTO public.app_rate_limits AS r VALUES(actor,operation,date_trunc('minute',now()),1)
 ON CONFLICT ON CONSTRAINT app_rate_limits_pkey DO UPDATE SET window_start=date_trunc('minute',now()),hits=CASE WHEN r.window_start=date_trunc('minute',now()) THEN r.hits+1 ELSE 1 END RETURNING hits INTO used;
 IF used>maximum THEN RAISE EXCEPTION 'Too many requests. Please wait a minute.' USING ERRCODE='P0001'; END IF;
END $$;
CREATE OR REPLACE FUNCTION public.can_view_creator(creator text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT EXISTS(SELECT 1 FROM public.profiles p WHERE p.id=creator AND NOT p.suspended AND
  (p.id=(SELECT auth.uid())::text OR coalesce(p.privacy_settings->>'privateAccount','false')<>'true'
  OR EXISTS(SELECT 1 FROM public.follows f WHERE f.following_id=creator AND f.follower_id=(SELECT auth.uid())::text AND f.status='accepted')));
$$;
CREATE OR REPLACE FUNCTION public.notify_user_event(recipient text,message text,event_type text) RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$
 INSERT INTO public.notifications(user_id,body) SELECT recipient,left(message,300) WHERE EXISTS(SELECT 1 FROM public.profiles WHERE id=recipient AND NOT suspended AND coalesce(notif_settings->>event_type,'true')<>'false');
$$;
CREATE OR REPLACE FUNCTION public.notify_user(recipient text,message text) RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$ SELECT public.notify_user_event(recipient,message,'systemAlerts'); $$;
-- Discoverable public identities; private content still requires accepted follow access.
DROP POLICY IF EXISTS "Visible profiles" ON public.profiles;
CREATE POLICY "Visible profiles" ON public.profiles FOR SELECT USING (id=(SELECT auth.uid())::text OR NOT suspended);
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS is_private boolean GENERATED ALWAYS AS (coalesce(privacy_settings->>'privateAccount','false')='true') STORED;
GRANT SELECT(is_private) ON public.profiles TO anon,authenticated;
GRANT SELECT(file_path) ON public.shop_items TO authenticated;

DROP POLICY IF EXISTS "Read own likes" ON public.video_likes;
CREATE POLICY "Read own likes" ON public.video_likes FOR SELECT TO authenticated USING(user_id=(SELECT auth.uid())::text);
DROP POLICY IF EXISTS "Read own saves" ON public.video_saves;
CREATE POLICY "Read own saves" ON public.video_saves FOR SELECT TO authenticated USING(user_id=(SELECT auth.uid())::text);
DROP POLICY IF EXISTS "Read visible comments" ON public.comments;
CREATE POLICY "Read visible comments" ON public.comments FOR SELECT USING(EXISTS(SELECT 1 FROM public.videos v WHERE v.id=video_id AND v.status='published' AND public.can_view_creator(v.creator_id)));
DROP POLICY IF EXISTS "Read own notifications" ON public.notifications;
CREATE POLICY "Read own notifications" ON public.notifications FOR SELECT TO authenticated USING(user_id=(SELECT auth.uid())::text);
DROP POLICY IF EXISTS "Mark own notifications" ON public.notifications;
CREATE POLICY "Mark own notifications" ON public.notifications FOR UPDATE TO authenticated USING(user_id=(SELECT auth.uid())::text) WITH CHECK(user_id=(SELECT auth.uid())::text);
DROP POLICY IF EXISTS "Read own messages" ON public.direct_messages;
CREATE POLICY "Read own messages" ON public.direct_messages FOR SELECT TO authenticated USING(sender_id=(SELECT auth.uid())::text OR recipient_id=(SELECT auth.uid())::text);
DROP POLICY IF EXISTS "Read own blocks" ON public.user_blocks;
CREATE POLICY "Read own blocks" ON public.user_blocks FOR SELECT TO authenticated USING(user_id=(SELECT auth.uid())::text);
DROP POLICY IF EXISTS "Read own deletion request" ON public.account_deletion_requests;
CREATE POLICY "Read own deletion request" ON public.account_deletion_requests FOR SELECT TO authenticated USING(user_id=(SELECT auth.uid())::text);
GRANT SELECT ON public.video_likes,public.video_saves,public.comments,public.notifications,public.direct_messages,public.user_blocks,public.account_deletion_requests TO authenticated;
GRANT UPDATE(read_at) ON public.notifications TO authenticated;

CREATE OR REPLACE FUNCTION public.set_video_like(video uuid,liked boolean) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor text := public.require_member(); creator text;
BEGIN
 PERFORM public.enforce_rate_limit(actor,'like',60);
 SELECT creator_id INTO creator FROM public.videos WHERE id=video AND status='published' AND public.can_view_creator(creator_id) FOR UPDATE;
 IF creator IS NULL THEN RAISE EXCEPTION 'Content unavailable'; END IF;
 IF liked THEN INSERT INTO public.video_likes VALUES(actor,video,now()) ON CONFLICT DO NOTHING;
 ELSE DELETE FROM public.video_likes WHERE user_id=actor AND video_id=video; END IF;
 UPDATE public.videos SET likes=(SELECT count(*) FROM public.video_likes WHERE video_id=video) WHERE id=video;
END $$;
CREATE OR REPLACE FUNCTION public.set_video_saved(video uuid,saved boolean) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor text := public.require_member();
BEGIN
 PERFORM public.enforce_rate_limit(actor,'save',60);
 IF NOT EXISTS(SELECT 1 FROM public.videos WHERE id=video AND status='published' AND public.can_view_creator(creator_id)) THEN RAISE EXCEPTION 'Content unavailable'; END IF;
 IF saved THEN INSERT INTO public.video_saves VALUES(actor,video,now()) ON CONFLICT DO NOTHING;
 ELSE DELETE FROM public.video_saves WHERE user_id=actor AND video_id=video; END IF;
END $$;
CREATE OR REPLACE FUNCTION public.set_follow(creator text,following boolean) RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor text := public.require_member(); result text;
BEGIN
 PERFORM public.enforce_rate_limit(actor,'follow',30);
 IF creator=actor OR NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=creator AND NOT suspended) THEN RAISE EXCEPTION 'Creator unavailable'; END IF;
 PERFORM id FROM public.profiles WHERE id IN(actor,creator) ORDER BY id FOR UPDATE;
 IF following THEN
  SELECT CASE WHEN is_private THEN 'pending' ELSE 'accepted' END INTO result FROM public.profiles WHERE id=creator;
  INSERT INTO public.follows(follower_id,following_id,status) VALUES(actor,creator,result) ON CONFLICT DO NOTHING;
  IF FOUND THEN PERFORM public.notify_user_event(creator,CASE WHEN result='pending' THEN 'New follow request. Review it in Privacy settings.' ELSE 'You have a new follower.' END,'newFollower'); END IF;
  SELECT status INTO result FROM public.follows WHERE follower_id=actor AND following_id=creator;
 ELSE DELETE FROM public.follows WHERE follower_id=actor AND following_id=creator; result := 'none'; END IF;
 UPDATE public.profiles SET followers=(SELECT count(*) FROM public.follows WHERE following_id=creator AND status='accepted') WHERE id=creator;
 UPDATE public.profiles SET following=(SELECT count(*) FROM public.follows WHERE follower_id=actor AND status='accepted') WHERE id=actor;
 RETURN result;
END $$;
CREATE OR REPLACE FUNCTION public.review_follow(follower text,accept boolean) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor text := public.require_member();
BEGIN
 PERFORM public.enforce_rate_limit(actor,'review_follow',30);
 PERFORM id FROM public.profiles WHERE id IN(actor,follower) ORDER BY id FOR UPDATE;
 IF accept THEN UPDATE public.follows SET status='accepted' WHERE follower_id=follower AND following_id=actor AND status='pending';
 ELSE DELETE FROM public.follows WHERE follower_id=follower AND following_id=actor AND status='pending'; END IF;
 UPDATE public.profiles SET followers=(SELECT count(*) FROM public.follows WHERE following_id=actor AND status='accepted') WHERE id=actor;
 UPDATE public.profiles SET following=(SELECT count(*) FROM public.follows WHERE follower_id=follower AND status='accepted') WHERE id=follower;
END $$;
CREATE OR REPLACE FUNCTION public.get_follow_requests() RETURNS TABLE(follower_id text,username text,display_name text) LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT f.follower_id,p.username,p.display_name FROM public.follows f JOIN public.profiles p ON p.id=f.follower_id WHERE f.following_id=public.require_member() AND f.status='pending';
$$;
CREATE OR REPLACE FUNCTION public.add_comment(video uuid,comment text) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor text := public.require_member(); result uuid; creator text;
BEGIN
 PERFORM public.enforce_rate_limit(actor,'comment',15);
 IF length(btrim(comment)) NOT BETWEEN 1 AND 2000 THEN RAISE EXCEPTION 'Comment must be 1–2000 characters'; END IF;
 SELECT creator_id INTO creator FROM public.videos WHERE id=video AND status='published' AND public.can_view_creator(creator_id);
 IF creator IS NULL OR EXISTS(SELECT 1 FROM public.user_blocks WHERE (user_id=creator AND blocked_id=actor) OR (user_id=actor AND blocked_id=creator)) THEN RAISE EXCEPTION 'Comments unavailable'; END IF;
 INSERT INTO public.comments(video_id,user_id,body) VALUES(video,actor,btrim(comment)) RETURNING id INTO result;
 IF creator<>actor THEN PERFORM public.notify_user_event(creator,'New comment on your content.','comments'); END IF; RETURN result;
END $$;
CREATE OR REPLACE FUNCTION public.send_message(recipient text,message text) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor text := public.require_member(); result uuid;
BEGIN
 PERFORM public.enforce_rate_limit(actor,'message',15);
 IF recipient=actor OR length(btrim(message)) NOT BETWEEN 1 AND 2000 OR NOT public.can_view_creator(recipient)
 OR NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=recipient AND NOT suspended AND coalesce(privacy_settings->>'allowMessages','true')<>'false')
 OR EXISTS(SELECT 1 FROM public.user_blocks WHERE (user_id=recipient AND blocked_id=actor) OR (user_id=actor AND blocked_id=recipient)) THEN RAISE EXCEPTION 'Message cannot be sent'; END IF;
 INSERT INTO public.direct_messages(sender_id,recipient_id,body) VALUES(actor,recipient,btrim(message)) RETURNING id INTO result;
 PERFORM public.notify_user_event(recipient,'You have a new message.','messages'); RETURN result;
END $$;
CREATE OR REPLACE FUNCTION public.set_user_block(target text,blocked boolean) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor text := public.require_member();
BEGIN
 IF actor=target THEN RAISE EXCEPTION 'Cannot block yourself'; END IF;
 IF blocked THEN INSERT INTO public.user_blocks VALUES(actor,target) ON CONFLICT DO NOTHING;
 ELSE DELETE FROM public.user_blocks WHERE user_id=actor AND blocked_id=target; END IF;
END $$;
CREATE OR REPLACE FUNCTION public.save_content(content_id uuid,title text,description text,category text,media_path text DEFAULT NULL) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor text := public.require_member(); result uuid;
BEGIN
 PERFORM public.enforce_rate_limit(actor,'publish',10);
 IF length(btrim(title)) NOT BETWEEN 1 AND 160 OR length(description)>5000 OR length(category)>50 OR (media_path IS NOT NULL AND (left(media_path,length(actor)+1)<>actor||'/' OR media_path LIKE '%..%')) THEN RAISE EXCEPTION 'Invalid content'; END IF;
 IF content_id IS NULL THEN
 INSERT INTO public.videos(creator_id,title,description,category,file_path,status) VALUES(actor,btrim(title),description,category,media_path,'pending') RETURNING id INTO result;
 ELSE UPDATE public.videos SET title=btrim(save_content.title),description=save_content.description,category=save_content.category,file_path=media_path,status='pending' WHERE id=content_id AND creator_id=actor RETURNING id INTO result; END IF;
 IF result IS NULL THEN RAISE EXCEPTION 'Content unavailable'; END IF;
 UPDATE public.profiles SET videos=(SELECT count(*) FROM public.videos WHERE creator_id=actor AND status='published') WHERE id=actor;
 RETURN result;
END $$;
CREATE OR REPLACE FUNCTION public.remove_content(content_id uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor text := public.require_member(); BEGIN
 UPDATE public.videos SET status='removed' WHERE id=content_id AND creator_id=actor;
 UPDATE public.profiles SET videos=(SELECT count(*) FROM public.videos WHERE creator_id=actor AND status='published') WHERE id=actor;
END $$;
CREATE OR REPLACE FUNCTION public.request_account_deletion() RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor text := public.require_member(); result uuid; BEGIN
 INSERT INTO public.account_deletion_requests(user_id) VALUES(actor) ON CONFLICT(user_id) DO UPDATE SET user_id=EXCLUDED.user_id RETURNING id INTO result;
 UPDATE public.profiles SET suspended=true WHERE id=actor;
 UPDATE public.live_streams SET status='ended',ended_at=now() WHERE creator_id=actor;
 RETURN result;
END $$;
CREATE OR REPLACE FUNCTION public.admin_overview() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN
 PERFORM public.require_admin();
 RETURN jsonb_build_object('profiles',(SELECT count(*) FROM public.profiles),'published',(SELECT count(*) FROM public.videos WHERE status='published'),
 'reports',coalesce((SELECT jsonb_agg(x) FROM (SELECT * FROM public.reports WHERE status='pending' ORDER BY created_at LIMIT 50)x),'[]'::jsonb),
 'content',coalesce((SELECT jsonb_agg(x) FROM (SELECT id,title,creator_id,description,file_path,created_at FROM public.videos WHERE status='pending' ORDER BY created_at LIMIT 50)x),'[]'::jsonb),
 'deletions',coalesce((SELECT jsonb_agg(x) FROM (SELECT * FROM public.account_deletion_requests WHERE status='pending' ORDER BY created_at LIMIT 50)x),'[]'::jsonb));
END $$;
CREATE OR REPLACE FUNCTION public.moderate_content(content_id uuid,decision text,note text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor text := public.require_admin(); creator text;
BEGIN
 IF decision NOT IN('published','removed') OR length(btrim(note)) NOT BETWEEN 3 AND 1000 THEN RAISE EXCEPTION 'A decision and review note are required'; END IF;
 UPDATE public.videos SET status=decision WHERE id=content_id RETURNING creator_id INTO creator;
 IF creator IS NULL THEN RAISE EXCEPTION 'Content unavailable'; END IF;
 INSERT INTO public.admin_audit_log(actor_id,action,target_id,note) VALUES(actor,'content:'||decision,content_id::text,note);
 UPDATE public.profiles SET videos=(SELECT count(*) FROM public.videos WHERE creator_id=creator AND status='published') WHERE id=creator;
 PERFORM public.notify_user(creator,'Your content review is complete: '||decision);
END $$;
CREATE OR REPLACE FUNCTION public.resolve_report(report_id uuid,decision text,note text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor text := public.require_admin(); BEGIN
 IF decision NOT IN('resolved','dismissed') OR length(btrim(note)) NOT BETWEEN 3 AND 1000 THEN RAISE EXCEPTION 'A decision and review note are required'; END IF;
 UPDATE public.reports SET status=decision WHERE id=report_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Report unavailable'; END IF;
 INSERT INTO public.admin_audit_log(actor_id,action,target_id,note) VALUES(actor,'report:'||decision,report_id::text,note);
END $$;
CREATE OR REPLACE FUNCTION public.suspend_member(member text,suspended boolean,note text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor text := public.require_admin(); BEGIN
 IF member=actor OR length(btrim(note)) NOT BETWEEN 3 AND 1000 THEN RAISE EXCEPTION 'Invalid action'; END IF;
 UPDATE public.profiles SET suspended=suspend_member.suspended WHERE id=member AND role<>'admin';
 IF NOT FOUND THEN RAISE EXCEPTION 'Member unavailable'; END IF;
 INSERT INTO public.admin_audit_log(actor_id,action,target_id,note) VALUES(actor,'suspension:'||suspended::text,member,note);
END $$;
CREATE OR REPLACE FUNCTION public.can_view_media(path text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT EXISTS(SELECT 1 FROM public.videos WHERE file_path=path AND ((status='published' AND public.can_view_creator(creator_id)) OR creator_id=(SELECT auth.uid())::text)) OR EXISTS(SELECT 1 FROM public.profiles WHERE id=(SELECT auth.uid())::text AND role='admin' AND NOT suspended);
$$;
-- New functions are deny-by-default; expose only bounded authenticated actions.
REVOKE ALL ON FUNCTION public.require_member(),public.require_admin(),public.enforce_rate_limit(text,text,integer),public.notify_user(text,text),public.notify_user_event(text,text,text) FROM PUBLIC,anon,authenticated;
DO $$ DECLARE signature text; BEGIN
 FOREACH signature IN ARRAY ARRAY['set_video_like(uuid,boolean)','set_video_saved(uuid,boolean)','set_follow(text,boolean)','review_follow(text,boolean)','get_follow_requests()','add_comment(uuid,text)','send_message(text,text)','set_user_block(text,boolean)','save_content(uuid,text,text,text,text)','remove_content(uuid)','request_account_deletion()','admin_overview()','moderate_content(uuid,text,text)','resolve_report(uuid,text,text)','suspend_member(text,boolean,text)','can_view_media(text)'] LOOP
 EXECUTE 'REVOKE ALL ON FUNCTION public.'||signature||' FROM PUBLIC,anon,authenticated';
 EXECUTE 'GRANT EXECUTE ON FUNCTION public.'||signature||' TO authenticated';
 END LOOP;
END $$;
COMMIT;

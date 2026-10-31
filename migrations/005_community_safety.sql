-- Apply after 004 in staging first. No automatic production execution.
BEGIN;
CREATE OR REPLACE FUNCTION public.can_view_creator(creator text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT EXISTS(SELECT 1 FROM public.profiles p WHERE p.id=creator AND NOT p.suspended AND p.role<>'deleted'
 AND NOT EXISTS(SELECT 1 FROM public.user_blocks b WHERE
  (b.user_id=creator AND b.blocked_id=(SELECT auth.uid())::text) OR
  (b.blocked_id=creator AND b.user_id=(SELECT auth.uid())::text))
 AND (p.id=(SELECT auth.uid())::text OR coalesce(p.privacy_settings->>'privateAccount','false')<>'true'
 OR EXISTS(SELECT 1 FROM public.follows f WHERE f.following_id=creator AND f.follower_id=(SELECT auth.uid())::text AND f.status='accepted')));
$$;

CREATE OR REPLACE FUNCTION public.set_follow(creator text,following boolean) RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor text := public.require_member(); result text;
BEGIN
 PERFORM public.enforce_rate_limit(actor,'follow',30);
 IF creator=actor OR NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=creator AND NOT suspended) THEN RAISE EXCEPTION 'Creator unavailable'; END IF;
 PERFORM id FROM public.profiles WHERE id IN(actor,creator) ORDER BY id FOR UPDATE;
 IF following IS NULL THEN RAISE EXCEPTION 'A follow decision is required'; END IF;
 IF following AND EXISTS(SELECT 1 FROM public.user_blocks WHERE (user_id=actor AND blocked_id=creator) OR (user_id=creator AND blocked_id=actor)) THEN RAISE EXCEPTION 'Creator unavailable'; END IF;
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
 IF accept IS NULL THEN RAISE EXCEPTION 'A follow decision is required'; END IF;
 IF accept AND EXISTS(SELECT 1 FROM public.user_blocks WHERE (user_id=actor AND blocked_id=follower) OR (user_id=follower AND blocked_id=actor)) THEN RAISE EXCEPTION 'Creator unavailable'; END IF;
 IF accept THEN UPDATE public.follows SET status='accepted' WHERE follower_id=follower AND following_id=actor AND status='pending';
 ELSE DELETE FROM public.follows WHERE follower_id=follower AND following_id=actor AND status='pending'; END IF;
 UPDATE public.profiles SET followers=(SELECT count(*) FROM public.follows WHERE following_id=actor AND status='accepted') WHERE id=actor;
 UPDATE public.profiles SET following=(SELECT count(*) FROM public.follows WHERE follower_id=follower AND status='accepted') WHERE id=follower;
END $$;

CREATE OR REPLACE FUNCTION public.set_user_block(target text,blocked boolean) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor text := public.require_member();
BEGIN
 PERFORM public.enforce_rate_limit(actor,'block',30);
 IF target IS NULL OR blocked IS NULL OR actor=target OR NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=target) THEN RAISE EXCEPTION 'Invalid block request'; END IF;
 -- Use the same lock order as follows and reviews to serialize relationship changes.
 PERFORM id FROM public.profiles WHERE id IN(actor,target) ORDER BY id FOR UPDATE;
 IF blocked THEN
  INSERT INTO public.user_blocks VALUES(actor,target) ON CONFLICT DO NOTHING;
  DELETE FROM public.follows WHERE (follower_id=actor AND following_id=target) OR (follower_id=target AND following_id=actor);
  UPDATE public.profiles p SET
   followers=(SELECT count(*) FROM public.follows WHERE following_id=p.id AND status='accepted'),
   following=(SELECT count(*) FROM public.follows WHERE follower_id=p.id AND status='accepted')
  WHERE p.id IN(actor,target);
 ELSE DELETE FROM public.user_blocks WHERE user_id=actor AND blocked_id=target;
 END IF;
END $$;

CREATE OR REPLACE FUNCTION public.moderate_content(content_id uuid,decision text,note text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor text := public.require_admin(); creator text;
BEGIN
 IF decision IS NULL OR note IS NULL OR decision NOT IN('published','removed') OR length(btrim(note)) NOT BETWEEN 3 AND 1000 THEN RAISE EXCEPTION 'A decision and review note are required'; END IF;
 UPDATE public.videos SET status=decision WHERE id=content_id RETURNING creator_id INTO creator;
 IF creator IS NULL THEN RAISE EXCEPTION 'Content unavailable'; END IF;
 INSERT INTO public.admin_audit_log(actor_id,action,target_id,note) VALUES(actor,'content:'||decision,content_id::text,note);
 UPDATE public.profiles SET videos=(SELECT count(*) FROM public.videos WHERE creator_id=creator AND status='published') WHERE id=creator;
 PERFORM public.notify_user(creator,'Your content review is complete: '||decision);
END $$;

CREATE OR REPLACE FUNCTION public.resolve_report(report_id uuid,decision text,note text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor text := public.require_admin(); BEGIN
 IF decision IS NULL OR note IS NULL OR decision NOT IN('resolved','dismissed') OR length(btrim(note)) NOT BETWEEN 3 AND 1000 THEN RAISE EXCEPTION 'A decision and review note are required'; END IF;
 UPDATE public.reports SET status=decision WHERE id=report_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Report unavailable'; END IF;
 INSERT INTO public.admin_audit_log(actor_id,action,target_id,note) VALUES(actor,'report:'||decision,report_id::text,note);
END $$;
CREATE OR REPLACE FUNCTION public.submit_safety_report(content_url text,details text,concern text) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor text:=public.require_member();result uuid;BEGIN
 PERFORM public.enforce_rate_limit(actor,'report',5);
 IF concern IS NULL OR content_url IS NULL OR details IS NULL OR concern NOT IN('other','child_safety','harassment') OR content_url !~ '^https?://' OR length(content_url)>2048 OR length(btrim(details)) NOT BETWEEN 10 AND 4000 THEN RAISE EXCEPTION 'A valid content URL and report details are required';END IF;
 INSERT INTO public.reports(reporter_id,reported_id,type,status,priority,content_url,details) VALUES(actor,NULL,concern,'pending',CASE WHEN concern='child_safety' THEN 'urgent' ELSE 'normal' END,content_url,btrim(details)) RETURNING id INTO result;RETURN result;
END $$;

CREATE OR REPLACE FUNCTION public.admin_overview() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN
 PERFORM public.require_admin();
 RETURN jsonb_build_object('profiles',(SELECT count(*) FROM public.profiles),'published',(SELECT count(*) FROM public.videos WHERE status='published'),
 'reports',coalesce((SELECT jsonb_agg(x) FROM (SELECT * FROM public.reports WHERE status='pending' ORDER BY CASE WHEN type='child_safety' THEN 0 ELSE 1 END,created_at,id LIMIT 50)x),'[]'::jsonb),
 'content',coalesce((SELECT jsonb_agg(x) FROM (SELECT id,title,creator_id,description,file_path,created_at FROM public.videos WHERE status='pending' ORDER BY created_at LIMIT 50)x),'[]'::jsonb),
 'deletions',coalesce((SELECT jsonb_agg(x) FROM (SELECT * FROM public.account_deletion_requests WHERE status='pending' ORDER BY created_at LIMIT 50)x),'[]'::jsonb));
END $$;
COMMIT;

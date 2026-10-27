BEGIN;
INSERT INTO storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
VALUES('videos','videos',false,104857600,ARRAY['video/mp4','video/webm'])
ON CONFLICT(id) DO UPDATE SET public=false,file_size_limit=EXCLUDED.file_size_limit,allowed_mime_types=EXCLUDED.allowed_mime_types;
DROP POLICY IF EXISTS "KS upload own video" ON storage.objects;
CREATE POLICY "KS upload own video" ON storage.objects FOR INSERT TO authenticated WITH CHECK(bucket_id='videos' AND (storage.foldername(name))[1]=(SELECT auth.uid())::text AND public.is_active_member());
DROP POLICY IF EXISTS "KS view authorized video" ON storage.objects;
CREATE POLICY "KS view authorized video" ON storage.objects FOR SELECT TO anon,authenticated USING(bucket_id='videos' AND public.can_view_media(name));
DROP POLICY IF EXISTS "KS remove own video" ON storage.objects;
CREATE POLICY "KS remove own video" ON storage.objects FOR DELETE TO authenticated USING(bucket_id='videos' AND (storage.foldername(name))[1]=(SELECT auth.uid())::text);
GRANT EXECUTE ON FUNCTION public.can_view_media(text) TO anon;
COMMIT;
BEGIN;
INSERT INTO storage.buckets(id,name,public,file_size_limit,allowed_mime_types) VALUES('shop-files','shop-files',false,52428800,ARRAY['application/pdf','application/epub+zip','application/zip','application/x-zip-compressed']) ON CONFLICT(id) DO UPDATE SET public=false,file_size_limit=EXCLUDED.file_size_limit,allowed_mime_types=EXCLUDED.allowed_mime_types;
DROP POLICY IF EXISTS "KS upload digital product" ON storage.objects;
CREATE POLICY "KS upload digital product" ON storage.objects FOR INSERT TO authenticated WITH CHECK(bucket_id='shop-files' AND (storage.foldername(name))[1]=(SELECT auth.uid())::text AND public.is_active_member());
DROP POLICY IF EXISTS "KS review own product" ON storage.objects;
CREATE POLICY "KS review own product" ON storage.objects FOR SELECT TO authenticated USING(bucket_id='shop-files' AND ((storage.foldername(name))[1]=(SELECT auth.uid())::text OR public.is_platform_admin()));
-- Customers receive short-lived download links from the authenticated Edge API
-- only after a paid receipt. Product files never have public bucket access.
COMMIT;

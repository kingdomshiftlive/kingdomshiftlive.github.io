BEGIN;
INSERT INTO storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
VALUES('videos','videos',false,104857600,ARRAY['video/mp4','video/webm'])
ON CONFLICT(id) DO UPDATE SET public=false,file_size_limit=EXCLUDED.file_size_limit,allowed_mime_types=EXCLUDED.allowed_mime_types;
DROP POLICY IF EXISTS "KS upload own video" ON storage.objects;
CREATE POLICY "KS upload own video" ON storage.objects FOR INSERT TO authenticated WITH CHECK(bucket_id='videos' AND (storage.foldername(name))[1]=(SELECT auth.uid())::text AND EXISTS(SELECT 1 FROM public.profiles WHERE id=(SELECT auth.uid())::text AND NOT suspended));
DROP POLICY IF EXISTS "KS view authorized video" ON storage.objects;
CREATE POLICY "KS view authorized video" ON storage.objects FOR SELECT TO authenticated USING(bucket_id='videos' AND public.can_view_media(name));
DROP POLICY IF EXISTS "KS remove own video" ON storage.objects;
CREATE POLICY "KS remove own video" ON storage.objects FOR DELETE TO authenticated USING(bucket_id='videos' AND (storage.foldername(name))[1]=(SELECT auth.uid())::text);
COMMIT;

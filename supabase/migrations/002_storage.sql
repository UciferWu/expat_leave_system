-- =====================================================================
-- 002 — 附件存储（病假证明等）/ Stockage des justificatifs
-- 文件路径格式 / chemin : <user_id>/<时间戳>-<文件名>
-- =====================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('leave-attachments', 'leave-attachments', false, 10485760,
        array['image/jpeg','image/png','image/webp','image/heic','application/pdf'])
on conflict (id) do nothing;

-- 本人上传到自己的文件夹 / Chacun dépose dans son propre dossier
create policy "leave_att_insert_own" on storage.objects for insert to authenticated
  with check (bucket_id = 'leave-attachments'
              and (storage.foldername(name))[1] = auth.uid()::text);

-- 本人、该申请的审批人、管理员可查看
-- Lecture : propriétaire, valideur de la demande, administrateur
create policy "leave_att_read" on storage.objects for select to authenticated
  using (bucket_id = 'leave-attachments' and (
           (storage.foldername(name))[1] = auth.uid()::text
           or public.is_admin()
           or exists (select 1 from public.leave_requests r
                       where r.attachment_path = storage.objects.name
                         and r.approver_id = auth.uid())));

-- 本人可删除自己尚未关联申请的文件 / Suppression de ses propres fichiers non rattachés
create policy "leave_att_delete_own" on storage.objects for delete to authenticated
  using (bucket_id = 'leave-attachments'
         and (storage.foldername(name))[1] = auth.uid()::text
         and not exists (select 1 from public.leave_requests r
                          where r.attachment_path = storage.objects.name));

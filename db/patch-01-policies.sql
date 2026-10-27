-- BandoLab — patch 01: policy di lettura mancanti e creazione automatica del profilo
-- Da eseguire DOPO schema.sql, nel SQL Editor di Supabase.

-- Tassonomia e contenuti collegati: lettura per gli utenti autenticati
create policy read_areas      on areas                 for select to authenticated using (true);
create policy read_entities   on entities              for select to authenticated using (true);
create policy read_subjects   on subjects              for select to authenticated using (true);
create policy read_topics     on topics                for select to authenticated using (true);
create policy read_profiles   on professional_profiles for select to authenticated using (true);
create policy read_pe         on profile_entities      for select to authenticated using (true);
create policy read_ps         on profile_subjects      for select to authenticated using (true);
create policy read_qp         on question_profiles     for select to authenticated using (true);

create policy read_msec on material_sections for select to authenticated
  using (exists (select 1 from materials m where m.env = material_sections.env and m.id = material_sections.material_id
    and (m.status = 'published' or current_role_t() in ('editor', 'reviewer', 'admin'))));
create policy read_mrel on material_related for select to authenticated using (true);

create policy read_paths on study_paths for select to authenticated
  using (status = 'published' or current_role_t() in ('editor', 'reviewer', 'admin'));
create policy read_steps on study_path_steps for select to authenticated using (true);

-- Tassonomia: scrittura solo admin
create policy admin_areas    on areas                 for all to authenticated using (current_role_t() = 'admin') with check (current_role_t() = 'admin');
create policy admin_entities on entities              for all to authenticated using (current_role_t() = 'admin') with check (current_role_t() = 'admin');
create policy admin_subjects on subjects              for all to authenticated using (current_role_t() = 'admin') with check (current_role_t() = 'admin');
create policy admin_topics   on topics                for all to authenticated using (current_role_t() = 'admin') with check (current_role_t() = 'admin');
create policy admin_profiles on professional_profiles for all to authenticated using (current_role_t() = 'admin') with check (current_role_t() = 'admin');

-- Dati personali
create policy own_path_progress on user_path_progress for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy own_reviewed on reviewed_attempts for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy own_interruptions on session_interruptions for select to authenticated
  using (exists (select 1 from quiz_sessions s where s.id = session_id and s.user_id = auth.uid()));

-- Staff
create policy staff_dups on duplicate_decisions for select to authenticated
  using (current_role_t() in ('reviewer', 'admin'));
create policy read_settings on editorial_settings for select to authenticated using (true);
create policy admin_settings on editorial_settings for all to authenticated
  using (current_role_t() = 'admin') with check (current_role_t() = 'admin');

-- Profilo creato automaticamente al primo accesso con Google (ruolo 'user')
create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles_user (id, display_name, email)
  values (new.id,
          coalesce(nullif(new.raw_user_meta_data->>'full_name', ''), split_part(new.email, '@', 1)),
          new.email)
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function handle_new_user();

-- Impostazioni editoriali iniziali
insert into editorial_settings (env) values ('demo'), ('real') on conflict do nothing;

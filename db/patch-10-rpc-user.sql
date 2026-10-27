-- BandoLab — patch 10: funzioni RPC dell'area utente
-- Da eseguire dopo patch-09.
--
-- Sostituiscono nel core: BL.completeMaterial, BL.markReviewed, BL.report.
-- Aggiungono: esportazione e cancellazione dei propri dati (GDPR).
-- Restringe inoltre le notifiche: l'utente può aggiornare solo read_at (prima poteva riscrivere titolo e testo).
--
-- Convenzioni come patch-07: security definer, search_path fisso, solo utenti autenticati;
-- condizioni previste -> {"ok": false, "error": "<codice>"}; dati non validi -> eccezione 22023.
-- STATO: APPLICATA al database il 27/10/2026 (migrazioni patch_10_rpc_user e patch_10b_delete_account), verificata con rpc-user.test.sql.

-- =========================================================
-- complete_material(p_env, p_mid)
-- Segna un materiale come completato: +8 XP una sola volta e avanzamento dei percorsi che lo contengono.
-- =========================================================
create or replace function public.complete_material(p_env public.env_t, p_mid text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_new boolean := false;
  v_done timestamptz;
begin
  if v_uid is null then raise exception 'Accesso richiesto' using errcode = '28000'; end if;
  if not exists (select 1 from public.materials m where m.env = p_env and m.id = p_mid and m.status = 'published') then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  insert into public.reading_progress (user_id, env, material_id, completed_at, updated_at)
  values (v_uid, p_env, p_mid, now(), now())
  on conflict (user_id, env, material_id) do nothing;
  if found then
    v_new := true;
  else
    select completed_at into v_done from public.reading_progress
    where user_id = v_uid and env = p_env and material_id = p_mid for update;
    if v_done is null then
      update public.reading_progress set completed_at = now(), updated_at = now()
      where user_id = v_uid and env = p_env and material_id = p_mid;
      v_new := true;
    end if;
  end if;

  if not v_new then
    return jsonb_build_object('ok', true, 'already', true);
  end if;

  insert into public.xp_events (user_id, env, amount, reason, ref)
  values (v_uid, p_env, 8, 'Materiale completato', p_mid);

  insert into public.user_path_progress (user_id, env, path_id, step_status, updated_at)
  select v_uid, p_env, s.path_id, jsonb_object_agg(s.id, 'done'), now()
  from public.study_path_steps s
  where s.env = p_env and s.type = 'material' and s.material_id = p_mid
  group by s.path_id
  on conflict (user_id, env, path_id) do update
    set step_status = public.user_path_progress.step_status || excluded.step_status,
        updated_at = now();

  return jsonb_build_object('ok', true, 'already', false, 'xp', 8);
end;
$$;

-- =========================================================
-- mark_reviewed(p_attempt_id)
-- Segna la revisione degli errori di un proprio tentativo concluso: +5 XP una sola volta.
-- =========================================================
create or replace function public.mark_reviewed(p_attempt_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_att public.attempts%rowtype;
begin
  if v_uid is null then raise exception 'Accesso richiesto' using errcode = '28000'; end if;
  select * into v_att from public.attempts
  where id = p_attempt_id and user_id = v_uid and status = 'completed';
  if not found then
    return jsonb_build_object('ok', false, 'error', 'attempt_not_found');
  end if;

  insert into public.reviewed_attempts (user_id, attempt_id) values (v_uid, p_attempt_id)
  on conflict do nothing;
  if not found then
    return jsonb_build_object('ok', true, 'already', true);
  end if;

  insert into public.xp_events (user_id, env, amount, reason, ref)
  values (v_uid, v_att.env, 5, 'Revisione degli errori', p_attempt_id::text);
  return jsonb_build_object('ok', true, 'already', false, 'xp', 5);
end;
$$;

-- =========================================================
-- create_report(p_env, p_qid, p_v, p_reason, p_text)
-- Segnalazione di una domanda pubblicata. Massimo 5 al giorno per utente.
-- =========================================================
create or replace function public.create_report(
  p_env public.env_t, p_qid text, p_v int, p_reason text, p_text text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_id uuid;
  v_notify boolean;
begin
  if v_uid is null then raise exception 'Accesso richiesto' using errcode = '28000'; end if;
  if p_reason is null or char_length(btrim(p_reason)) < 2 or char_length(p_reason) > 60 then
    raise exception 'Motivo non valido' using errcode = '22023';
  end if;
  if p_text is null or char_length(btrim(p_text)) < 10 or char_length(p_text) > 2000 then
    raise exception 'La descrizione deve avere da 10 a 2000 caratteri' using errcode = '22023';
  end if;
  if not exists (select 1 from public.question_versions qv
                 where qv.env = p_env and qv.question_id = p_qid and qv.v = p_v and qv.status = 'published') then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;
  if (select count(*) from public.reports r
      where r.reporter_id = v_uid and r.created_at > now() - interval '1 day') >= 5 then
    return jsonb_build_object('ok', false, 'error', 'too_many');
  end if;

  insert into public.reports (env, question_id, version, reporter_id, reason, text)
  values (p_env, p_qid, p_v, v_uid, btrim(p_reason), btrim(p_text))
  returning id into v_id;

  select coalesce((select up.notif_content from public.user_prefs up
                   where up.user_id = v_uid and up.env = p_env), true) into v_notify;
  if v_notify then
    insert into public.notifications (user_id, env, type, title, body)
    values (v_uid, p_env, 'content', 'Segnalazione inviata',
            'La segnalazione è in coda di revisione. Riceverai un avviso quando verrà gestita.');
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

-- =========================================================
-- Notifiche: l'utente può modificare soltanto read_at
-- =========================================================
revoke update on public.notifications from authenticated, anon;
grant update (read_at) on public.notifications to authenticated;

-- =========================================================
-- export_my_data() — esportazione dei propri dati (GDPR, portabilità)
-- =========================================================
create or replace function public.export_my_data()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Accesso richiesto' using errcode = '28000'; end if;
  return jsonb_build_object(
    'exported_at', now(),
    'profile', (select to_jsonb(p) from public.profiles_user p where p.id = v_uid),
    'preferences', coalesce((select jsonb_agg(to_jsonb(u)) from public.user_prefs u where u.user_id = v_uid), '[]'),
    'attempts', coalesce((
      select jsonb_agg(to_jsonb(a) || jsonb_build_object('items', coalesce((
        select jsonb_agg(to_jsonb(i) order by i.position) from public.attempt_items i where i.attempt_id = a.id), '[]'))
        order by a.finished_at)
      from public.attempts a where a.user_id = v_uid), '[]'),
    'open_session', (select to_jsonb(s) from public.quiz_sessions s where s.user_id = v_uid limit 1),
    'xp_events', coalesce((select jsonb_agg(to_jsonb(x) order by x.at) from public.xp_events x where x.user_id = v_uid), '[]'),
    'reading_progress', coalesce((select jsonb_agg(to_jsonb(r)) from public.reading_progress r where r.user_id = v_uid), '[]'),
    'path_progress', coalesce((select jsonb_agg(to_jsonb(p)) from public.user_path_progress p where p.user_id = v_uid), '[]'),
    'reviewed_attempts', coalesce((select jsonb_agg(to_jsonb(r)) from public.reviewed_attempts r where r.user_id = v_uid), '[]'),
    'notifications', coalesce((select jsonb_agg(to_jsonb(n) order by n.created_at) from public.notifications n where n.user_id = v_uid), '[]'),
    'reports', coalesce((select jsonb_agg(to_jsonb(r) order by r.created_at) from public.reports r where r.reporter_id = v_uid), '[]'));
end;
$$;

-- =========================================================
-- delete_my_account(p_confirm) — cancellazione dell'account e di tutti i dati personali
-- Richiede la conferma testuale 'ELIMINA'. Gli account di redazione, o che hanno contenuti o decisioni a proprio nome
-- (anche se ora sono utenti semplici), non si cancellano da qui: l'amministratore deve prima riassegnarli.
-- Le segnalazioni restano in forma anonima; i registri di audit perdono il riferimento all'autore.
-- =========================================================
create or replace function public.delete_my_account(p_confirm text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_role public.role_t;
begin
  if v_uid is null then raise exception 'Accesso richiesto' using errcode = '28000'; end if;
  if p_confirm is distinct from 'ELIMINA' then
    raise exception 'Conferma mancante: digitare ELIMINA' using errcode = '22023';
  end if;
  select role into v_role from public.profiles_user where id = v_uid;
  if v_role is null then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if v_role <> 'user'
     or exists (select 1 from public.question_versions qv where qv.author_id = v_uid or qv.reviewer_id = v_uid)
     or exists (select 1 from public.materials m where m.author_id = v_uid or m.reviewer_id = v_uid)
     or exists (select 1 from public.duplicate_decisions d where d.actor_id = v_uid)
     or exists (select 1 from public.reports r where r.assignee_id = v_uid) then
    return jsonb_build_object('ok', false, 'error', 'staff_account');
  end if;
  delete from auth.users where id = v_uid;   -- i dati personali seguono in cascata
  return jsonb_build_object('ok', true);
end;
$$;

-- =========================================================
-- PERMESSI
-- =========================================================
revoke all on function public.complete_material(public.env_t, text)                          from public, anon;
revoke all on function public.mark_reviewed(uuid)                                            from public, anon;
revoke all on function public.create_report(public.env_t, text, int, text, text)             from public, anon;
revoke all on function public.export_my_data()                                               from public, anon;
revoke all on function public.delete_my_account(text)                                        from public, anon;

grant execute on function public.complete_material(public.env_t, text)                       to authenticated;
grant execute on function public.mark_reviewed(uuid)                                         to authenticated;
grant execute on function public.create_report(public.env_t, text, int, text, text)          to authenticated;
grant execute on function public.export_my_data()                                            to authenticated;
grant execute on function public.delete_my_account(text)                                     to authenticated;

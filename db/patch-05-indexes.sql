-- BandoLab — patch 05: indici sulle chiavi collegate (Performance Advisor, suggerimenti)
-- L'avviso "attempts_user_idx non usato" va ignorato: l'indice servirà quando ci saranno tentativi.

create index if not exists attempt_items_question_fk_idx on attempt_items (env, question_id, version);
create index if not exists audit_log_actor_idx           on audit_log (actor_id);
create index if not exists duplicate_decisions_actor_idx on duplicate_decisions (actor_id);
create index if not exists entities_area_idx             on entities (env, area_id);
create index if not exists material_related_related_idx  on material_related (env, related_id);
create index if not exists materials_author_idx          on materials (author_id);
create index if not exists materials_subject_idx         on materials (env, subject_id);
create index if not exists materials_topic_idx           on materials (env, topic_id);
create index if not exists materials_reviewer_idx        on materials (reviewer_id);
create index if not exists notifications_user_idx        on notifications (user_id);
create index if not exists profile_entities_entity_idx   on profile_entities (env, entity_id);
create index if not exists profile_subjects_subject_idx  on profile_subjects (env, subject_id);
create index if not exists question_profiles_profile_idx on question_profiles (env, profile_id);
create index if not exists question_versions_author_idx   on question_versions (author_id);
create index if not exists question_versions_subject_idx  on question_versions (env, subject_id);
create index if not exists question_versions_topic_idx    on question_versions (env, topic_id);
create index if not exists question_versions_reviewer_idx on question_versions (reviewer_id);
create index if not exists questions_current_idx         on questions (env, id, current_version);
create index if not exists reports_assignee_idx          on reports (assignee_id);
create index if not exists reports_question_idx          on reports (env, question_id, version);
create index if not exists reports_reporter_idx          on reports (reporter_id);
create index if not exists reviewed_attempts_attempt_idx on reviewed_attempts (attempt_id);
create index if not exists session_interruptions_sess_idx on session_interruptions (session_id);
create index if not exists topics_subject_idx            on topics (env, subject_id);
create index if not exists xp_events_user_idx            on xp_events (user_id);

-- ============================================================================
-- POC comparaison ASE : schema PostgreSQL "compa_ase"
-- Version du schema : 1.0
--
-- Prerequis : la base PostgreSQL (option -n du script) doit deja exister, ex. :
--     createdb -h <hote> -U <login> compa
-- Execution :
--     psql -h <hote> -U <login> -d compa -f create_schema.sql
--
-- Le script est idempotent : il peut etre rejoue sans effacer les donnees.
-- Aucun mot de passe n'est defini ici (voir la section 7 pour le role Grafana).
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

CREATE SCHEMA IF NOT EXISTS compa_ase;

-- ----------------------------------------------------------------------------
-- 1. Version du schema
--    Le script de comparaison verifie sa presence avant de demarrer :
--    SELECT to_regclass('compa_ase.schema_version') IS NOT NULL;
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS compa_ase.schema_version (
    version     text        PRIMARY KEY,
    applied_at  timestamptz NOT NULL DEFAULT now()
);

INSERT INTO compa_ase.schema_version (version) VALUES ('1.0')
ON CONFLICT (version) DO NOTHING;

-- ----------------------------------------------------------------------------
-- 2. Tables de reference
-- ----------------------------------------------------------------------------

-- Une ligne par couple (instance1/base1, instance2/base2) compare.
CREATE TABLE IF NOT EXISTS compa_ase.ref_execution (
    refid       bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    instance1   text        NOT NULL,
    base1       text        NOT NULL,
    instance2   text        NOT NULL,
    base2       text        NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ux_ref_execution UNIQUE (instance1, base1, instance2, base2)
);
COMMENT ON TABLE compa_ase.ref_execution IS
    'Reference d''execution : un refid par combinaison instance1/base1/instance2/base2 (reutilise si elle existe).';

-- Une ligne par execution du script.
CREATE TABLE IF NOT EXISTS compa_ase.run (
    run_id      bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    refid       bigint      NOT NULL REFERENCES compa_ase.ref_execution (refid),
    ts_exec     timestamptz NOT NULL DEFAULT now(),
    ts_fin      timestamptz,
    statut      text        NOT NULL DEFAULT 'EN_COURS'
                CHECK (statut IN ('EN_COURS', 'TERMINE', 'ERREUR')),
    message     text
);
CREATE INDEX IF NOT EXISTS ix_run_refid_ts ON compa_ase.run (refid, ts_exec DESC);
COMMENT ON TABLE compa_ase.run IS
    'Une ligne par execution (run_id unique) ; les tables diff_* referencent run_id avec suppression en cascade.';

-- Acces aux instances ASE : un login par instance.
-- POC : mot de passe stocke en clair (acces limite au role du script).
CREATE TABLE IF NOT EXISTS compa_ase.config_compa_ase (
    instance     text    PRIMARY KEY,
    host         text    NOT NULL,
    port         integer NOT NULL DEFAULT 5000,
    login        text    NOT NULL,
    password     text    NOT NULL,
    actif        boolean NOT NULL DEFAULT true,
    commentaire  text
);
COMMENT ON TABLE compa_ase.config_compa_ase IS
    'Credentials ASE par instance. Ne jamais versionner de contenu de cette table dans git.';

-- Regles d'exclusion du bruit de comparaison.
--   cle_pattern : motif SQL LIKE applique a la cle de la ligne ('%' = toutes)
--   colonne     : colonne de valeur concernee, '*' = toute la ligne
--   action      : IGNORE (ecart non enregistre) ou ATTENDU (enregistre avec attendu = true)
CREATE TABLE IF NOT EXISTS compa_ase.exclusion_rules (
    rule_id      bigint  GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    module       text    NOT NULL
                 CHECK (module IN ('inst_config', 'db_size', 'db_options', 'obj_tables',
                                   'obj_indexes', 'obj_code', 'obj_source')),
    cle_pattern  text    NOT NULL DEFAULT '%',
    colonne      text    NOT NULL DEFAULT '*',
    action       text    NOT NULL DEFAULT 'IGNORE' CHECK (action IN ('IGNORE', 'ATTENDU')),
    motif        text,
    actif        boolean NOT NULL DEFAULT true,
    CONSTRAINT ux_exclusion_rules UNIQUE (module, cle_pattern, colonne)
);

INSERT INTO compa_ase.exclusion_rules (module, cle_pattern, colonne, action, motif)
VALUES ('obj_indexes', '%', 'statstamp', 'IGNORE',
        'Date de mise a jour des statistiques : differe presque toujours entre deux instances')
ON CONFLICT (module, cle_pattern, colonne) DO NOTHING;

-- ----------------------------------------------------------------------------
-- 3. Tables de differences : une par module
--    Colonnes communes : diff_id, run_id, refid, ts_exec, type_diff, attendu
--    Valeurs de l'instance 1 / base 1 prefixees r1_, instance 2 / base 2 prefixees r2_
--    Une ligne consolidee par difference.
-- ----------------------------------------------------------------------------

-- 3.1 inst_config : cle = name
CREATE TABLE IF NOT EXISTS compa_ase.diff_inst_config (
    diff_id          bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id           bigint      NOT NULL REFERENCES compa_ase.run (run_id) ON DELETE CASCADE,
    refid            bigint      NOT NULL REFERENCES compa_ase.ref_execution (refid),
    ts_exec          timestamptz NOT NULL,
    type_diff        text        NOT NULL CHECK (type_diff IN ('ONLY_R1', 'ONLY_R2', 'DIFF')),
    attendu          boolean     NOT NULL DEFAULT false,
    name             text        NOT NULL,
    r1_value         text,
    r1_value_in_use  text,
    r2_value         text,
    r2_value_in_use  text,
    CONSTRAINT ux_diff_inst_config UNIQUE (run_id, name)
);

-- 3.2 db_size : cle = segment (data / log / mixed)
CREATE TABLE IF NOT EXISTS compa_ase.diff_db_size (
    diff_id      bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id       bigint      NOT NULL REFERENCES compa_ase.run (run_id) ON DELETE CASCADE,
    refid        bigint      NOT NULL REFERENCES compa_ase.ref_execution (refid),
    ts_exec      timestamptz NOT NULL,
    type_diff    text        NOT NULL CHECK (type_diff IN ('ONLY_R1', 'ONLY_R2', 'DIFF')),
    attendu      boolean     NOT NULL DEFAULT false,
    segment      text        NOT NULL,
    r1_segmap    text,
    r1_size_mb   numeric,
    r1_page_size integer,
    r2_segmap    text,
    r2_size_mb   numeric,
    r2_page_size integer,
    CONSTRAINT ux_diff_db_size UNIQUE (run_id, segment)
);

-- Mise a niveau : comparaison de la taille de page (segment special 'page_size')
ALTER TABLE compa_ase.diff_db_size ADD COLUMN IF NOT EXISTS r1_page_size integer;
ALTER TABLE compa_ase.diff_db_size ADD COLUMN IF NOT EXISTS r2_page_size integer;

-- 3.3 db_options : une seule ligne par run (pas de cle)
--     r1_options / r2_options : options decodees, lisibles dans Grafana
CREATE TABLE IF NOT EXISTS compa_ase.diff_db_options (
    diff_id      bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id       bigint      NOT NULL REFERENCES compa_ase.run (run_id) ON DELETE CASCADE,
    refid        bigint      NOT NULL REFERENCES compa_ase.ref_execution (refid),
    ts_exec      timestamptz NOT NULL,
    type_diff    text        NOT NULL CHECK (type_diff IN ('ONLY_R1', 'ONLY_R2', 'DIFF')),
    attendu      boolean     NOT NULL DEFAULT false,
    r1_status    text,
    r1_status2   text,
    r1_status3   text,
    r1_status4   text,
    r1_options   text,
    r2_status    text,
    r2_status2   text,
    r2_status3   text,
    r2_status4   text,
    r2_options   text,
    CONSTRAINT ux_diff_db_options UNIQUE (run_id)
);

-- 3.4 obj_tables : cle = table_name + column_name
--     r1_attributs / r2_attributs : status decode (nullabilite, identity...)
CREATE TABLE IF NOT EXISTS compa_ase.diff_obj_tables (
    diff_id       bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id        bigint      NOT NULL REFERENCES compa_ase.run (run_id) ON DELETE CASCADE,
    refid         bigint      NOT NULL REFERENCES compa_ase.ref_execution (refid),
    ts_exec       timestamptz NOT NULL,
    type_diff     text        NOT NULL CHECK (type_diff IN ('ONLY_R1', 'ONLY_R2', 'DIFF')),
    attendu       boolean     NOT NULL DEFAULT false,
    table_name    text        NOT NULL,
    column_name   text        NOT NULL,
    r1_type       text,
    r1_length     integer,
    r1_prec       integer,
    r1_scale      integer,
    r1_status     text,
    r1_attributs  text,
    r2_type       text,
    r2_length     integer,
    r2_prec       integer,
    r2_scale      integer,
    r2_status     text,
    r2_attributs  text,
    CONSTRAINT ux_diff_obj_tables UNIQUE (run_id, table_name, column_name)
);

-- 3.5 obj_indexes : cle = table_name + index_name
--     statstamp est conserve pour affichage ; la regle d'exclusion par defaut
--     l'empeche de declencher un ecart a lui seul.
CREATE TABLE IF NOT EXISTS compa_ase.diff_obj_indexes (
    diff_id       bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id        bigint      NOT NULL REFERENCES compa_ase.run (run_id) ON DELETE CASCADE,
    refid         bigint      NOT NULL REFERENCES compa_ase.ref_execution (refid),
    ts_exec       timestamptz NOT NULL,
    type_diff     text        NOT NULL CHECK (type_diff IN ('ONLY_R1', 'ONLY_R2', 'DIFF')),
    attendu       boolean     NOT NULL DEFAULT false,
    table_name    text        NOT NULL,
    index_name    text        NOT NULL,
    r1_status     text,
    r1_columns    text,
    r1_statstamp  timestamp,
    r2_status     text,
    r2_columns    text,
    r2_statstamp  timestamp,
    CONSTRAINT ux_diff_obj_indexes UNIQUE (run_id, table_name, index_name)
);

-- Mise a niveau d'un schema cree avant l'ajout de la comparaison des colonnes d'index
ALTER TABLE compa_ase.diff_obj_indexes ADD COLUMN IF NOT EXISTS r1_columns text;
ALTER TABLE compa_ase.diff_obj_indexes ADD COLUMN IF NOT EXISTS r2_columns text;

-- 3.6 obj_code : presence des vues (V), procedures (P) et triggers (TR)
--     cle = object_name + object_type
CREATE TABLE IF NOT EXISTS compa_ase.diff_obj_code (
    diff_id      bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id       bigint      NOT NULL REFERENCES compa_ase.run (run_id) ON DELETE CASCADE,
    refid        bigint      NOT NULL REFERENCES compa_ase.ref_execution (refid),
    ts_exec      timestamptz NOT NULL,
    type_diff    text        NOT NULL CHECK (type_diff IN ('ONLY_R1', 'ONLY_R2', 'DIFF')),
    attendu      boolean     NOT NULL DEFAULT false,
    object_name  text        NOT NULL,
    object_type  text        NOT NULL,
    r1_present   boolean     NOT NULL DEFAULT false,
    r2_present   boolean     NOT NULL DEFAULT false,
    CONSTRAINT ux_diff_obj_code UNIQUE (run_id, object_name, object_type)
);

-- 3.7 obj_source : contenu du code ; cle = object_name + object_type
--     Le hash MD5 sert a la comparaison ; les textes (reconstitues a partir de
--     syscomments.colid) sont stockes uniquement pour les objets en ecart.
CREATE TABLE IF NOT EXISTS compa_ase.diff_obj_source (
    diff_id        bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id         bigint      NOT NULL REFERENCES compa_ase.run (run_id) ON DELETE CASCADE,
    refid          bigint      NOT NULL REFERENCES compa_ase.ref_execution (refid),
    ts_exec        timestamptz NOT NULL,
    type_diff      text        NOT NULL CHECK (type_diff IN ('ONLY_R1', 'ONLY_R2', 'DIFF')),
    attendu        boolean     NOT NULL DEFAULT false,
    object_name    text        NOT NULL,
    object_type    text        NOT NULL,
    r1_hash        text,
    r1_nb_lignes   integer,
    r1_source      text,
    r2_hash        text,
    r2_nb_lignes   integer,
    r2_source      text,
    CONSTRAINT ux_diff_obj_source UNIQUE (run_id, object_name, object_type)
);

-- Index de consultation (selecteur de run Grafana, filtres par type d'ecart)
DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['diff_inst_config', 'diff_db_size', 'diff_db_options',
                             'diff_obj_tables', 'diff_obj_indexes', 'diff_obj_code',
                             'diff_obj_source']
    LOOP
        EXECUTE format('CREATE INDEX IF NOT EXISTS ix_%s_run ON compa_ase.%I (run_id, type_diff)', t, t);
        EXECUTE format('CREATE INDEX IF NOT EXISTS ix_%s_refid_ts ON compa_ase.%I (refid, ts_exec DESC)', t, t);
    END LOOP;
END
$$;

-- ----------------------------------------------------------------------------
-- 4. Fonctions utilitaires pour le script de comparaison
-- ----------------------------------------------------------------------------

-- Retourne le refid de la combinaison, en le creant s'il n'existe pas.
CREATE OR REPLACE FUNCTION compa_ase.get_or_create_refid(
    p_instance1 text, p_base1 text, p_instance2 text, p_base2 text
) RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
    v_refid bigint;
BEGIN
    SELECT refid INTO v_refid
      FROM compa_ase.ref_execution
     WHERE instance1 = p_instance1 AND base1 = p_base1
       AND instance2 = p_instance2 AND base2 = p_base2;

    IF v_refid IS NULL THEN
        INSERT INTO compa_ase.ref_execution (instance1, base1, instance2, base2)
        VALUES (p_instance1, p_base1, p_instance2, p_base2)
        ON CONFLICT (instance1, base1, instance2, base2) DO NOTHING
        RETURNING refid INTO v_refid;

        -- cas de concurrence : un autre processus vient de la creer
        IF v_refid IS NULL THEN
            SELECT refid INTO v_refid
              FROM compa_ase.ref_execution
             WHERE instance1 = p_instance1 AND base1 = p_base1
               AND instance2 = p_instance2 AND base2 = p_base2;
        END IF;
    END IF;

    RETURN v_refid;
END
$$;

-- Ouvre une execution et retourne son run_id.
CREATE OR REPLACE FUNCTION compa_ase.start_run(p_refid bigint)
RETURNS bigint
LANGUAGE sql
AS $$
    INSERT INTO compa_ase.run (refid) VALUES (p_refid) RETURNING run_id;
$$;

-- Cloture une execution.
CREATE OR REPLACE FUNCTION compa_ase.end_run(p_run_id bigint, p_statut text, p_message text DEFAULT NULL)
RETURNS void
LANGUAGE sql
AS $$
    UPDATE compa_ase.run
       SET ts_fin = now(), statut = p_statut, message = p_message
     WHERE run_id = p_run_id;
$$;

-- ----------------------------------------------------------------------------
-- 5. Vues pour Grafana
-- ----------------------------------------------------------------------------

-- Selecteur de run : timestamp + instance1/base1 + instance2/base2
CREATE OR REPLACE VIEW compa_ase.v_run_selector AS
SELECT r.run_id,
       r.ts_exec,
       r.statut,
       e.refid,
       e.instance1, e.base1, e.instance2, e.base2,
       to_char(r.ts_exec AT TIME ZONE 'Europe/Paris', 'YYYY-MM-DD HH24:MI:SS')
           || ' | ' || e.instance1 || '.' || e.base1
           || ' vs ' || e.instance2 || '.' || e.base2 AS libelle
  FROM compa_ase.run r
  JOIN compa_ase.ref_execution e USING (refid);

-- Synthese des ecarts par run, module et type (page d'accueil Grafana)
CREATE OR REPLACE VIEW compa_ase.v_synthese_run AS
          SELECT run_id, 'inst_config'::text AS module, type_diff, attendu, count(*) AS nb FROM compa_ase.diff_inst_config GROUP BY run_id, type_diff, attendu
UNION ALL SELECT run_id, 'db_size',     type_diff, attendu, count(*) FROM compa_ase.diff_db_size     GROUP BY run_id, type_diff, attendu
UNION ALL SELECT run_id, 'db_options',  type_diff, attendu, count(*) FROM compa_ase.diff_db_options  GROUP BY run_id, type_diff, attendu
UNION ALL SELECT run_id, 'obj_tables',  type_diff, attendu, count(*) FROM compa_ase.diff_obj_tables  GROUP BY run_id, type_diff, attendu
UNION ALL SELECT run_id, 'obj_indexes', type_diff, attendu, count(*) FROM compa_ase.diff_obj_indexes GROUP BY run_id, type_diff, attendu
UNION ALL SELECT run_id, 'obj_code',    type_diff, attendu, count(*) FROM compa_ase.diff_obj_code    GROUP BY run_id, type_diff, attendu
UNION ALL SELECT run_id, 'obj_source',  type_diff, attendu, count(*) FROM compa_ase.diff_obj_source  GROUP BY run_id, type_diff, attendu;

-- ----------------------------------------------------------------------------
-- 6. Documentation des colonnes cles
-- ----------------------------------------------------------------------------
COMMENT ON COLUMN compa_ase.diff_inst_config.type_diff IS 'ONLY_R1 : present seulement cote 1 ; ONLY_R2 : seulement cote 2 ; DIFF : valeurs differentes';
COMMENT ON COLUMN compa_ase.diff_inst_config.attendu   IS 'true si l''ecart correspond a une regle d''exclusion de type ATTENDU';

-- ----------------------------------------------------------------------------
-- 7. Role Grafana en lecture seule
--    Le role est cree SANS mot de passe (aucun secret dans git).
--    Apres execution, definir le mot de passe manuellement :
--        ALTER ROLE grafana_ro LOGIN PASSWORD '<a_definir>';
-- ----------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'grafana_ro') THEN
        CREATE ROLE grafana_ro NOLOGIN;
    END IF;
END
$$;

GRANT USAGE ON SCHEMA compa_ase TO grafana_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA compa_ase TO grafana_ro;
-- config_compa_ase contient des mots de passe : jamais lisible par Grafana
REVOKE ALL ON compa_ase.config_compa_ase FROM grafana_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA compa_ase GRANT SELECT ON TABLES TO grafana_ro;

COMMIT;

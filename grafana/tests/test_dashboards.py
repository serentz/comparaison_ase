#!/usr/bin/env python3
"""Tests des dashboards Grafana.

Structure : toujours executee.
Requetes SQL : avec COMPA_TEST_PG=1 et COMPA_TEST_DB=<base avec schema compa_ase> (PGHOST, PGUSER...).
Les donnees de test sont chargees par compare.py a partir de python/tests/fixtures (30 ecarts).
"""
import json, os, re, subprocess, sys, unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
DASH = os.path.join(ROOT, "grafana", "dashboards")
sys.path.insert(0, os.path.join(ROOT, "grafana"))
import build_dashboards as bd  # noqa: E402

MODULES = ["inst_config", "db_size", "db_options", "obj_tables", "obj_indexes", "obj_code", "obj_source"]
EXPECTED = {"inst_config": 2, "db_size": 2, "db_options": 1, "obj_tables": 9,
            "obj_indexes": 4, "obj_code": 4, "obj_source": 8}


def load_all():
    out = {}
    for f in sorted(os.listdir(DASH)):
        if f.endswith(".json"):
            with open(os.path.join(DASH, f), encoding="utf-8") as fh:
                out[f] = json.load(fh)
    return out


class Structure(unittest.TestCase):
    def setUp(self):
        self.d = load_all()

    def test_eight_dashboards(self):
        self.assertEqual(len(self.d), 8)
        self.assertIn("compa-home.json", self.d)

    def test_unique_uids_and_titles(self):
        uids = [x["uid"] for x in self.d.values()]
        titles = [x["title"] for x in self.d.values()]
        self.assertEqual(len(set(uids)), 8)
        self.assertEqual(len(set(titles)), 8)

    def test_panel_ids_unique(self):
        for n, x in self.d.items():
            ids = [p["id"] for p in x["panels"]]
            self.assertEqual(len(ids), len(set(ids)), n)

    def test_tag_and_navigation(self):
        for n, x in self.d.items():
            self.assertIn("compa_ase", x["tags"], n)
            nav = [l for l in x["links"] if l.get("type") == "dashboards"]
            self.assertEqual(len(nav), 1, n)
            self.assertEqual(nav[0]["tags"], ["compa_ase"])
            self.assertTrue(nav[0]["includeVars"], n)

    def test_run_variable_identical(self):
        ref = None
        for n, x in self.d.items():
            v = [t for t in x["templating"]["list"] if t["name"] == "run"]
            self.assertEqual(len(v), 1, n)
            ref = ref or v[0]["query"]
            self.assertEqual(v[0]["query"], ref, n)

    def test_datasource_everywhere(self):
        for n, x in self.d.items():
            for p in x["panels"]:
                for t in p.get("targets", []):
                    self.assertEqual(t["datasource"]["uid"], "compa_ase_pg", n)
                    self.assertEqual(t["format"], "table")

    def test_home_links_to_existing_modules(self):
        uids = {x["uid"] for x in self.d.values()}
        for m in MODULES:
            self.assertIn("compa-" + m, uids)

    def test_committed_json_is_generated_json(self):
        gen = bd.build()
        for name, dash in gen.items():
            self.assertEqual(json.loads(json.dumps(dash)), self.d[name], name)


PG = os.environ.get("COMPA_TEST_PG") == "1"


def psql(sql, db):
    r = subprocess.run(["psql", "-X", "-At", "-v", "ON_ERROR_STOP=1", "-d", db, "-c", sql],
                       capture_output=True, text=True)
    if r.returncode:
        raise RuntimeError(r.stderr + "\n" + sql[:400])
    return r.stdout.strip()


def substitute(sql, run_id, objet="sp_get_customer|P", filtre=""):
    vals = {"run": run_id, "objet": objet, "filtre": filtre}
    def rep(m):
        v = vals[m.group(1)]
        return "'" + str(v).replace("'", "''") + "'"
    sql = re.sub(r"\$\{(run|objet|filtre):sqlstring\}", rep, sql)
    sql = re.sub(r"\$\{(run|objet|filtre)(?::[a-z]+)?\}", lambda m: str(vals[m.group(1)]), sql)
    sql = sql.replace("$__timeFilter", "").replace("${__data.fields.Module}", "x")
    return sql


@unittest.skipUnless(PG, "COMPA_TEST_PG=1 requis")
class Sql(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.db = os.environ["COMPA_TEST_DB"]
        psql("select 1", cls.db)
        cls.d = load_all()
        refid = psql("select compa_ase.get_or_create_refid('G1','poc_db','G2','poc_db')", cls.db)
        cls.rid = psql(f"select compa_ase.start_run({refid})", cls.db)
        r = subprocess.run([sys.executable, os.path.join(ROOT, "python", "compare.py"),
                            "--csv-dir", os.path.join(ROOT, "python", "tests", "fixtures"),
                            "--run-id", cls.rid, "--refid", refid, "-n", cls.db]
                           + (["-H", os.environ["PGHOST"]] if os.environ.get("PGHOST") else [])
                           + (["-U", os.environ["PGUSER"]] if os.environ.get("PGUSER") else []),
                           capture_output=True, text=True)
        assert r.returncode == 0, r.stdout + r.stderr
        psql(f"select compa_ase.end_run({cls.rid}, 'TERMINE', 'test')", cls.db)

    def test_all_panel_queries_run(self):
        n = 0
        for name, x in self.d.items():
            for p in x["panels"]:
                for t in p.get("targets", []):
                    q = substitute(t["rawSql"], self.rid).rstrip().rstrip(";")
                    try:
                        psql(f"select count(*) from ({q}) q", self.db)
                    except RuntimeError as e:
                        self.fail(f"{name} / {p['title']}: {e}")
                    n += 1
        self.assertGreaterEqual(n, 40)

    def test_variable_query(self):
        q = self.d["compa-home.json"]["templating"]["list"][0]["query"]
        out = psql(q, self.db)
        self.assertIn(f"{self.rid}|", out)

    def test_module_counts(self):
        for m, exp in EXPECTED.items():
            x = self.d[f"compa-{m}.json"]
            tables = [p for p in x["panels"] if p["type"] == "table" and p["title"] in ("Écarts", "Objets en écart")]
            self.assertTrue(tables, m)
            q = substitute(tables[0]["targets"][0]["rawSql"], self.rid).rstrip().rstrip(";")
            self.assertEqual(int(psql(f"select count(*) from ({q}) q", self.db)), exp, m)

    def test_objet_variable(self):
        x = self.d["compa-obj_source.json"]
        v = [t for t in x["templating"]["list"] if t["name"] == "objet"][0]
        q = substitute(v["query"], self.rid)
        out = psql(q, self.db).splitlines()
        self.assertEqual(len(out), 4)
        self.assertTrue(any("sp_get_customer" in l for l in out))

    def test_synthese_rows(self):
        x = self.d["compa-home.json"]
        t = [p for p in x["panels"] if p["title"] == "Écarts par module"][0]
        q = substitute(t["targets"][0]["rawSql"], self.rid).rstrip().rstrip(";")
        self.assertEqual(int(psql(f"select count(*) from ({q}) q", self.db)), 7)


if __name__ == "__main__":
    unittest.main(verbosity=2)

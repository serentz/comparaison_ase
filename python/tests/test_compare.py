#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Tests de compare.py (bibliotheque standard uniquement).

    cd python && python3 -m unittest discover -s tests -v

Test d'integration PostgreSQL (optionnel) : definir COMPA_TEST_PG=1 ainsi que PGHOST, PGPORT,
PGUSER (et PGPASSWORD si besoin) et COMPA_TEST_DB (base ou create_schema.sql a deja ete execute).
"""
import contextlib
import io
import os
import shutil
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)

import compare  # noqa: E402
import make_fixtures  # noqa: E402

FIXTURES = os.path.join(HERE, "fixtures")

EXPECTED_COUNTS = {
    "inst_config": 2, "db_size": 2, "db_options": 1, "obj_tables": 9,
    "obj_indexes": 4, "obj_code": 4, "obj_source": 8,
}


def keys(results, module, type_diff=None):
    return {d.key_text for d in results[module] if type_diff in (None, d.type_diff)}


class FixturesTest(unittest.TestCase):
    def test_committed_fixtures_are_up_to_date(self):
        tmp = tempfile.mkdtemp()
        try:
            make_fixtures.write_fixtures(tmp)
            for name in sorted(os.listdir(tmp)):
                with open(os.path.join(tmp, name), encoding="utf-8") as a, \
                        open(os.path.join(FIXTURES, name), encoding="utf-8") as b:
                    self.assertEqual(a.read(), b.read(), f"{name} different : relancer make_fixtures.py")
        finally:
            shutil.rmtree(tmp)


class ComparisonTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.results = compare.run_comparison(FIXTURES, compare.DEFAULT_RULES)

    def test_counts_per_module(self):
        self.assertEqual({m: len(d) for m, d in self.results.items()}, EXPECTED_COUNTS)

    def test_instance_and_db_modules(self):
        self.assertEqual(keys(self.results, "inst_config"), {"deadlock retries", "print deadlock information"})
        self.assertEqual(keys(self.results, "db_size"), {"data", "log"})
        self.assertEqual(keys(self.results, "db_options"), {""})

    def test_tables(self):
        self.assertEqual(keys(self.results, "obj_tables", "DIFF"),
                         {"customers.email", "customers.phone", "orders.total_amount"})
        self.assertEqual(keys(self.results, "obj_tables", "ONLY_R1"),
                         {"order_items.discount", "tmp_import.import_id", "tmp_import.payload"})
        self.assertEqual(keys(self.results, "obj_tables", "ONLY_R2"),
                         {"products.barcode", "archive_orders.order_id", "archive_orders.archived_at"})

    def test_indexes_columns_difference_is_reported(self):
        res = [r for r in self.results["obj_indexes"] if r.key == ("customers", "uq_customers_email")][0]
        self.assertEqual((res.rec1["columns"], res.rec2["columns"]), ("email", "email,phone"))
        self.assertIn("columns", res.cols)

    def test_indexes_statstamp_noise_is_ignored(self):
        found = keys(self.results, "obj_indexes")
        self.assertEqual(found, {"customers.uq_customers_email", "products.pk_products",
                                 "orders.idx_orders_date", "orders.idx_orders_customer"})
        # idx_customers_name et pk_customers ne different que par statstamp : ecart ignore
        self.assertNotIn("customers.idx_customers_name", found)
        self.assertNotIn("customers.pk_customers", found)

    def test_code_presence(self):
        self.assertEqual(keys(self.results, "obj_code", "ONLY_R1"), {"sp_purge_orders.P", "trg_customers_upd.TR"})
        self.assertEqual(keys(self.results, "obj_code", "ONLY_R2"), {"sp_archive_orders.P", "v_customer_orders.V"})

    def test_source_diff_and_identical_witness(self):
        self.assertEqual(keys(self.results, "obj_source", "DIFF"),
                         {"sp_get_customer.P", "sp_calc_order_total.P", "v_orders_summary.V", "trg_orders_audit.TR"})
        self.assertNotIn("sp_list_products.P", keys(self.results, "obj_source"))

    def test_long_source_is_split_in_several_chunks(self):
        with open(os.path.join(FIXTURES, "r1_obj_source.csv"), encoding="utf-8") as fh:
            chunks = [ln for ln in fh if ln.startswith("sp_calc_order_total|")]
        self.assertGreaterEqual(len(chunks), 3)

    def test_decoded_fields(self):
        by_key = {d.key_text: d for d in self.results["obj_tables"]}
        self.assertEqual(by_key["customers.phone"].rec1["attributs"], "NULL")
        self.assertEqual(by_key["customers.phone"].rec2["attributs"], "NOT NULL")
        opts = self.results["db_options"][0]
        self.assertEqual(opts.rec1["options"], "select into/bulkcopy")
        self.assertEqual(opts.rec2["options"], "trunc log on chkpt")
        size = {d.key_text: d for d in self.results["db_size"]}["data"]
        self.assertEqual((str(size.rec1["size_mb"]), str(size.rec2["size_mb"])), ("100", "120"))

    def test_page_size_difference_is_reported(self):
        mod = [m for m in compare.MODULES if m.name == "db_size"][0]
        rows = lambda p: [(2, {"db_name": "x", "segmap": "3", "size_mb": "10", "page_size": p})]
        a = mod.prepare(mod, rows("2048"), "r1", {})
        b = mod.prepare(mod, rows("16384"), "r2", {})
        self.assertEqual(a[("page_size",)]["page_size"], 2048)
        self.assertNotEqual(a[("page_size",)]["page_size"], b[("page_size",)]["page_size"])

    def test_source_only_side_keeps_text(self):
        d = {x.key_text: x for x in self.results["obj_source"]}["sp_purge_orders.P"]
        self.assertIsNone(d.rec2)
        self.assertIn("delete from orders", d.rec1["source"])


class RulesTest(unittest.TestCase):
    def run_with(self, rules):
        return compare.run_comparison(FIXTURES, rules)

    def test_attendu_row_rule(self):
        res = self.run_with(compare.DEFAULT_RULES + [compare.Rule.make("inst_config", "deadlock%", "*", "ATTENDU")])
        flags = {d.key_text: d.attendu for d in res["inst_config"]}
        self.assertEqual(flags, {"deadlock retries": True, "print deadlock information": False})

    def test_ignore_row_rule_with_like_pattern(self):
        res = self.run_with(compare.DEFAULT_RULES + [compare.Rule.make("obj_tables", "tmp_import.%", "*", "IGNORE")])
        self.assertEqual(len(res["obj_tables"]), 7)
        self.assertNotIn("tmp_import.payload", keys(res, "obj_tables"))

    def test_ignore_column_rule(self):
        # ignorer 'length' : customers.email ne different plus que par length -> disparait
        res = self.run_with(compare.DEFAULT_RULES + [compare.Rule.make("obj_tables", "customers.email", "length", "IGNORE")])
        self.assertNotIn("customers.email", keys(res, "obj_tables"))

    def test_attendu_column_rule_needs_all_columns_covered(self):
        rules = compare.DEFAULT_RULES + [compare.Rule.make("obj_tables", "orders.total_amount", "length", "ATTENDU")]
        res = self.run_with(rules)
        d = {x.key_text: x for x in res["obj_tables"]}["orders.total_amount"]
        self.assertFalse(d.attendu)     # prec differe aussi, non couvert
        rules.append(compare.Rule.make("obj_tables", "orders.total_amount", "prec", "ATTENDU"))
        d = {x.key_text: x for x in self.run_with(rules)["obj_tables"]}["orders.total_amount"]
        self.assertTrue(d.attendu)

    def test_without_default_rule_statstamp_is_reported(self):
        res = self.run_with([])
        self.assertIn("customers.idx_customers_name", keys(res, "obj_indexes"))


class ParsingTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp)

    def write(self, name, content):
        path = os.path.join(self.tmp, name)
        with open(path, "w", encoding="utf-8", newline="") as fh:
            fh.write(content)
        return path

    def test_missing_file(self):
        with self.assertRaises(compare.CsvError):
            compare.read_csv(os.path.join(self.tmp, "absent.csv"), ["a"])

    def test_empty_file_without_header_is_an_error(self):
        with self.assertRaisesRegex(compare.CsvError, "vide"):
            compare.read_csv(self.write("e.csv", "\n  \n"), ["a"])

    def test_header_only_means_no_rows(self):
        self.assertEqual(compare.read_csv(self.write("h.csv", "a|b\n"), ["a", "b"]), [])

    def test_bad_header(self):
        with self.assertRaisesRegex(compare.CsvError, "en-tete invalide"):
            compare.read_csv(self.write("b.csv", "a|c\n1|2\n"), ["a", "b"])

    def test_wrong_column_count(self):
        with self.assertRaisesRegex(compare.CsvError, "ligne 2"):
            compare.read_csv(self.write("c.csv", "a|b\n1|2|3\n"), ["a", "b"])

    def test_trim_null_blank_lines_crlf_and_bom(self):
        path = self.write("t.csv", "﻿a|b\r\n  1  |  NULL \r\n\r\n x|  \r\n")
        rows = compare.read_csv(path, ["a", "b"])
        self.assertEqual([r for _, r in rows], [{"a": "1", "b": None}, {"a": "x", "b": ""}])

    def test_duplicate_key(self):
        path = self.write("d.csv", "name|value|value_in_use\nx|1|1\nx|2|2\n")
        mod = compare.MODULES[0]
        with self.assertRaisesRegex(compare.CsvError, "double"):
            compare.build_records(mod, compare.read_csv(path, mod.columns), path, {})

    def test_null_key_is_rejected(self):
        path = self.write("n.csv", "name|value|value_in_use\nNULL|1|1\n")
        mod = compare.MODULES[0]
        with self.assertRaisesRegex(compare.CsvError, "NULL"):
            compare.build_records(mod, compare.read_csv(path, mod.columns), path, {})

    def test_invalid_number(self):
        path = self.write("i.csv", "table_name|column_name|type_name|length|prec|scale|status\nt|c|int|abc|NULL|NULL|0\n")
        mod = [m for m in compare.MODULES if m.name == "obj_tables"][0]
        with self.assertRaisesRegex(compare.CsvError, "length"):
            compare.build_records(mod, compare.read_csv(path, mod.columns), path, {})

    def test_timestamp_formats(self):
        iso = compare.parse_ts("2026-10-12 11:00:00")
        self.assertEqual(compare.parse_ts("2026-10-12T11:00:00"), iso)
        self.assertEqual(compare.parse_ts("Oct 12 2026 11:00AM"), iso)
        self.assertEqual(compare.parse_ts("Oct  2 2026  9:05PM").hour, 21)
        with self.assertRaises(ValueError):
            compare.parse_ts("pas une date")

    def test_segment_of(self):
        self.assertEqual([compare.segment_of(s) for s in (3, 4, 7, 11)], ["data", "log", "mixed", "data"])

    def test_source_normalization_ignores_line_endings_and_trailing_spaces(self):
        mod = [m for m in compare.MODULES if m.name == "obj_source"][0]

        def prep(text):
            hexa = text.encode("utf-8").hex()
            rows = [(2, {"object_name": "p", "object_type": "P", "colid": "1", "text_hex": hexa})]
            return compare.prepare_obj_source(mod, rows, "x.csv", {})[("p", "P")]["hash"]

        self.assertEqual(prep("a  \nb\n"), prep("a\r\nb\r\n\r\n"))
        self.assertNotEqual(prep("a\nb"), prep("a\nc"))

    def test_source_chunks_are_reassembled_in_colid_order(self):
        mod = [m for m in compare.MODULES if m.name == "obj_source"][0]
        rows = [(2, {"object_name": "p", "object_type": "P", "colid": "2", "text_hex": b"world".hex()}),
                (3, {"object_name": "p", "object_type": "P", "colid": "1", "text_hex": b"hello ".hex()})]
        rec = compare.prepare_obj_source(mod, rows, "x.csv", {})[("p", "P")]
        self.assertEqual(rec["source"], "hello world")
        rows.append((4, dict(rows[0][1])))
        with self.assertRaisesRegex(compare.CsvError, "double"):
            compare.prepare_obj_source(mod, rows, "x.csv", {})

    def test_invalid_hex(self):
        mod = [m for m in compare.MODULES if m.name == "obj_source"][0]
        rows = [(2, {"object_name": "p", "object_type": "P", "colid": "1", "text_hex": "zz"})]
        with self.assertRaisesRegex(compare.CsvError, "hexadecimal"):
            compare.prepare_obj_source(mod, rows, "x.csv", {})


class CliTest(unittest.TestCase):
    def call(self, argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = compare.main(argv)
        return code, out.getvalue(), err.getvalue()

    def test_dry_run_ok(self):
        code, out, _ = self.call(["--csv-dir", FIXTURES, "--dry-run"])
        self.assertEqual(code, compare.EXIT_OK)
        self.assertIn("30 ecart(s) detecte(s)", out)

    def test_missing_csv_gives_exit_2(self):
        tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, tmp)
        code, _, err = self.call(["--csv-dir", tmp, "--dry-run"])
        self.assertEqual(code, compare.EXIT_CSV)
        self.assertIn("fichier manquant", err)

    def test_run_id_required_without_dry_run(self):
        with self.assertRaises(SystemExit):
            with contextlib.redirect_stderr(io.StringIO()):
                compare.parse_args(["--csv-dir", FIXTURES])

    def test_unreachable_postgres_gives_exit_3(self):
        if not shutil.which("psql"):
            self.skipTest("psql absent")
        code, _, err = self.call(["--csv-dir", FIXTURES, "--run-id", "1", "--refid", "1",
                                  "-H", "127.0.0.1", "-p", "1", "-n", "x", "-U", "x"])
        self.assertEqual(code, compare.EXIT_PG)
        self.assertIn("PostgreSQL", err)


@unittest.skipUnless(os.environ.get("COMPA_TEST_PG") and shutil.which("psql"),
                     "definir COMPA_TEST_PG=1 (+ PGHOST/PGPORT/PGUSER, COMPA_TEST_DB) pour tester sur PostgreSQL")
class PostgresIntegrationTest(unittest.TestCase):
    """Necessite une base ou sql/postgres/create_schema.sql a ete execute."""

    def pg(self):
        return compare.Pg(os.environ.get("PGHOST"), os.environ.get("PGPORT"), os.environ["COMPA_TEST_DB"],
                          os.environ.get("PGUSER"), os.environ.get("PGPASSWORD"))

    def call(self, argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = compare.main(argv)
        return code, out.getvalue(), err.getvalue()

    def args(self, run_id, refid, csv_dir=FIXTURES):
        return ["--csv-dir", csv_dir, "--run-id", str(run_id), "--refid", str(refid), "-n", os.environ["COMPA_TEST_DB"]]

    def new_run(self, pg):
        refid = pg.query("select compa_ase.get_or_create_refid('TEST1','poc_db','TEST2','poc_db') as r")[0]["r"]
        run_id = pg.query(f"select compa_ase.start_run({refid}) as r")[0]["r"]
        return int(run_id), int(refid)

    def test_full_run_is_written(self):
        pg = self.pg()
        run_id, refid = self.new_run(pg)
        code, out, err = self.call(self.args(run_id, refid))
        self.assertEqual(code, compare.EXIT_OK, err)
        total = sum(int(pg.query(f"select count(*) as n from compa_ase.{m.table} where run_id = {run_id}")[0]["n"])
                    for m in compare.MODULES)
        self.assertEqual(total, sum(EXPECTED_COUNTS.values()))
        run = pg.query(f"select statut, message from compa_ase.run where run_id = {run_id}")[0]
        self.assertEqual((run["statut"], run["message"]), ("TERMINE", "30 ecart(s)"))
        selector = pg.query(f"select libelle from compa_ase.v_run_selector where run_id = {run_id}")[0]["libelle"]
        self.assertIn("TEST1.poc_db vs TEST2.poc_db", selector)
        # le texte multi-lignes du code source est stocke tel quel
        src = pg.query(f"select r1_source from compa_ase.diff_obj_source where run_id = {run_id} "
                       f"and object_name = 'sp_purge_orders'")[0]["r1_source"]
        self.assertIn("delete from orders", src)
        # le NULL du cote absent est bien un NULL SQL
        n = pg.query(f"select count(*) as n from compa_ase.diff_obj_tables where run_id = {run_id} "
                     f"and type_diff = 'ONLY_R1' and r2_type is null")[0]["n"]
        self.assertEqual(int(n), 3)

    def test_unknown_run_gives_exit_3(self):
        code, _, err = self.call(self.args(999999, 1))
        self.assertEqual(code, compare.EXIT_PG)
        self.assertIn("introuvable", err)

    def test_refid_mismatch_gives_exit_3(self):
        pg = self.pg()
        run_id, refid = self.new_run(pg)
        code, _, err = self.call(self.args(run_id, refid + 1000))
        self.assertEqual(code, compare.EXIT_PG)
        self.assertIn("incoherence", err)

    def test_invalid_csv_marks_run_in_error(self):
        pg = self.pg()
        run_id, refid = self.new_run(pg)
        tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, tmp)
        make_fixtures.write_fixtures(tmp)
        os.remove(os.path.join(tmp, "r2_db_size.csv"))
        code, _, _ = self.call(self.args(run_id, refid, tmp))
        self.assertEqual(code, compare.EXIT_CSV)
        run = pg.query(f"select statut, message from compa_ase.run where run_id = {run_id}")[0]
        self.assertEqual(run["statut"], "ERREUR")
        self.assertIn("fichier manquant", run["message"])
        n = pg.query(f"select count(*) as n from compa_ase.diff_inst_config where run_id = {run_id}")[0]["n"]
        self.assertEqual(int(n), 0)

    def test_rerun_same_run_is_rejected_and_rolled_back(self):
        pg = self.pg()
        run_id, refid = self.new_run(pg)
        self.assertEqual(self.call(self.args(run_id, refid))[0], compare.EXIT_OK)
        code, _, err = self.call(self.args(run_id, refid))
        self.assertEqual(code, compare.EXIT_PG)
        total = sum(int(pg.query(f"select count(*) as n from compa_ase.{m.table} where run_id = {run_id}")[0]["n"])
                    for m in compare.MODULES)
        self.assertEqual(total, 30)      # pas de doublons : la 2e insertion a ete annulee


if __name__ == "__main__":
    unittest.main()

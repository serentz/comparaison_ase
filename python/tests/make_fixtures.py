#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Genere les CSV factices (r1_/r2_ pour les 7 modules) qui reproduisent les ecarts voulus des
scripts sql/ase_test/01_create_poc_db_instance1.sql et 02_create_poc_db_instance2.sql.

Usage : python make_fixtures.py <dossier_de_sortie>

Ces fichiers servent a tester compare.py sans instance ASE. Les valeurs de statuts
(syscolumns.status, sysindexes.status...) sont plausibles mais synthetiques.
"""
import os
import sys

NULL = "NULL"

# --- inst_config -------------------------------------------------------------
INST_COMMON = [
    ("allow updates to system tables", "0", "0"),
    ("enable cis", "1", "1"),
    ("number of user connections", "25", "25"),
    ("recovery interval in minutes", "5", "5"),
]
INST_R1 = INST_COMMON + [("deadlock retries", "5", "5"), ("print deadlock information", "0", "0")]
INST_R2 = INST_COMMON + [("deadlock retries", "10", "10"), ("print deadlock information", "1", "1")]

# --- db_size / db_options ---------------------------------------------------
PAGE = "16384"      # @@maxpagesize identique des deux cotes (propriete du serveur, pas de la base)
DB_SIZE_R1 = [("poc_db", "3", "100", PAGE), ("poc_db", "4", "40", PAGE)]
DB_SIZE_R2 = [("poc_db", "3", "120", PAGE), ("poc_db", "4", "50", PAGE)]
DB_OPTIONS_R1 = [("poc_db", "4", "0", "0", "0")]      # select into/bulkcopy/pllsort
DB_OPTIONS_R2 = [("poc_db", "8", "0", "0", "0")]      # trunc log on chkpt

# --- obj_tables : (table, colonne, type, length, prec, scale, status) -----------
def _t(table, col, typ, length, prec=NULL, scale=NULL, status="0"):
    return (table, col, typ, str(length), str(prec), str(scale), str(status))


def tables(side):
    r2 = side == 2
    rows = [
        _t("customers", "customer_id", "int", 4, status=128),
        _t("customers", "first_name", "varchar", 50),
        _t("customers", "last_name", "varchar", 50),
        _t("customers", "email", "varchar", 150 if r2 else 100, status=8),
        _t("customers", "phone", "varchar", 20, status=0 if r2 else 8),
        _t("customers", "created_at", "datetime", 8),
        _t("products", "product_id", "int", 4, status=128),
        _t("products", "label", "varchar", 100),
        _t("products", "unit_price", "numeric", 6, 10, 2),
        _t("orders", "order_id", "int", 4, status=128),
        _t("orders", "customer_id", "int", 4),
        _t("orders", "order_date", "datetime", 8),
        _t("orders", "total_amount", "numeric", 7 if r2 else 6, 14 if r2 else 12, 2),
        _t("order_items", "order_item_id", "int", 4, status=128),
        _t("order_items", "order_id", "int", 4),
        _t("order_items", "product_id", "int", 4),
        _t("order_items", "quantity", "int", 4),
        _t("audit_log", "log_id", "int", 4, status=128),
        _t("audit_log", "table_name", "varchar", 30),
        _t("audit_log", "action_type", "char", 3),
        _t("audit_log", "changed_at", "datetime", 8),
    ]
    if r2:
        rows += [_t("products", "barcode", "varchar", 20, status=8),
                 _t("archive_orders", "order_id", "int", 4),
                 _t("archive_orders", "archived_at", "datetime", 8, status=0)]
    else:
        rows += [_t("order_items", "discount", "numeric", 3, 5, 2, 8),
                 _t("tmp_import", "import_id", "int", 4),
                 _t("tmp_import", "payload", "varchar", 255, status=8)]
    return rows


# --- obj_indexes : (table, index, status, columns, statstamp) --------------------------
# status : 2 = unique, 16 = clustered, 2048 = cle primaire
def indexes(side):
    r2 = side == 2
    stamp = "1970-01-01 00:00:00" if r2 else "2026-10-12 11:05:00"   # update statistics sur customers (base 1 seulement)
    rows = [
        ("customers", "idx_customers_name", "0", "last_name,first_name", stamp),
        ("customers", "pk_customers", "2066", "customer_id", stamp),
        ("customers", "uq_customers_email", "0" if r2 else "2", "email,phone" if r2 else "email", stamp),
        ("products", "pk_products", "2050" if r2 else "2066", "product_id", NULL),
        ("orders", "pk_orders", "2066", "order_id", NULL),
        ("order_items", "pk_order_items", "2066", "order_item_id", NULL),
        ("order_items", "idx_order_items_order", "0", "order_id", NULL),
        ("audit_log", "pk_audit_log", "2066", "log_id", NULL),
    ]
    rows.append(("orders", "idx_orders_customer", "0", "customer_id", NULL) if r2
                else ("orders", "idx_orders_date", "0", "order_date", NULL))
    return rows


# --- obj_code / obj_source ----------------------------------------------------
SP_GET_CUSTOMER_1 = """create procedure sp_get_customer @customer_id int
as
begin
    select customer_id, first_name, last_name, email, phone
    from customers
    where customer_id = @customer_id
end
"""
SP_GET_CUSTOMER_2 = """create procedure sp_get_customer @customer_id int
as
begin
    select customer_id, first_name, last_name, email, phone, created_at
    from customers
    where customer_id = @customer_id
    order by last_name
end
"""
SP_LIST_PRODUCTS = """create procedure sp_list_products
as
begin
    select product_id, label, unit_price
    from products
    order by label
end
"""
SP_CALC = """create procedure sp_calc_order_total @order_id int
as
begin
    /* ----------------------------------------------------------------------
       Procedure de calcul du total TTC d'une commande.
       Cette zone de commentaire est volontairement longue afin que le texte
       de la procedure soit decoupe en plusieurs enregistrements dans la table
       syscomments (blocs de 255 caracteres). Le module obj_source doit donc
       reconstituer le code complet a partir de la colonne colid avant de
       comparer les deux bases. Le commentaire est identique des deux cotes.
       Regle de calcul : somme des lignes de commande (quantite x prix unitaire)
       puis application du taux de TVA applicable a la commande. Les remises
       ne sont pas prises en compte dans cette version de la procedure.
       Historique : version initiale pour le jeu de test du POC de comparaison.
       ---------------------------------------------------------------------- */
    declare @total numeric(14,2)

    select @total = sum(oi.quantity * p.unit_price)
    from order_items oi, products p
    where oi.order_id = @order_id
      and oi.product_id = p.product_id

    /* taux de TVA : %(taux)s dans la base %(base)s */
    select @total = @total * %(taux)s

    select @order_id as order_id, @total as total_ttc
end
"""
SP_PURGE = """create procedure sp_purge_orders
as
begin
    delete from orders
    where order_date < dateadd(yy, -3, getdate())
end
"""
SP_ARCHIVE = """create procedure sp_archive_orders
as
begin
    insert archive_orders (order_id, archived_at)
    select order_id, getdate()
    from orders
    where order_date < dateadd(yy, -1, getdate())
end
"""
V_SUMMARY_1 = """create view v_orders_summary as
    select o.order_id, c.last_name, o.order_date, o.total_amount
    from orders o, customers c
    where o.customer_id = c.customer_id
"""
V_SUMMARY_2 = V_SUMMARY_1 + "      and o.total_amount > 0\n"
V_CUSTOMER_ORDERS = """create view v_customer_orders as
    select c.customer_id, c.last_name, count(o.order_id) as nb_orders
    from customers c, orders o
    where c.customer_id = o.customer_id
    group by c.customer_id, c.last_name
"""
TRG_AUDIT_1 = """create trigger trg_orders_audit on orders
for insert, update
as
begin
    insert audit_log (table_name, action_type) values ('orders', 'IU')
end
"""
TRG_AUDIT_2 = """create trigger trg_orders_audit on orders
for insert, update, delete
as
begin
    insert audit_log (table_name, action_type) values ('orders', 'IUD')
end
"""
TRG_CUSTOMERS = """create trigger trg_customers_upd on customers
for update
as
begin
    insert audit_log (table_name, action_type) values ('customers', 'U')
end
"""

# (nom, type, source base 1, source base 2) ; None = absent de ce cote
OBJECTS = [
    ("sp_get_customer", "P", SP_GET_CUSTOMER_1, SP_GET_CUSTOMER_2),
    ("sp_list_products", "P", SP_LIST_PRODUCTS, SP_LIST_PRODUCTS),
    ("sp_calc_order_total", "P", SP_CALC % {"taux": "1.20", "base": "1"}, SP_CALC % {"taux": "1.21", "base": "2"}),
    ("sp_purge_orders", "P", SP_PURGE, None),
    ("sp_archive_orders", "P", None, SP_ARCHIVE),
    ("v_orders_summary", "V", V_SUMMARY_1, V_SUMMARY_2),
    ("v_customer_orders", "V", None, V_CUSTOMER_ORDERS),
    ("trg_orders_audit", "TR", TRG_AUDIT_1, TRG_AUDIT_2),
    ("trg_customers_upd", "TR", TRG_CUSTOMERS, None),
]


def obj_code(side):
    return [(n, t) for n, t, s1, s2 in OBJECTS if (s1 if side == 1 else s2) is not None]


def obj_source(side):
    """Un bloc de 255 caracteres par ligne (comme syscomments), contenu en hexadecimal."""
    rows = []
    for name, otype, s1, s2 in OBJECTS:
        text = s1 if side == 1 else s2
        if text is None:
            continue
        for i in range(0, len(text), 255):
            rows.append((name, otype, str(i // 255 + 1), text[i:i + 255].encode("utf-8").hex()))
    return rows


# --- ecriture -----------------------------------------------------------------
HEADERS = {
    "inst_config": ["name", "value", "value_in_use"],
    "db_size": ["db_name", "segmap", "size_mb", "page_size"],
    "db_options": ["db_name", "status", "status2", "status3", "status4"],
    "obj_tables": ["table_name", "column_name", "type_name", "length", "prec", "scale", "status"],
    "obj_indexes": ["table_name", "index_name", "status", "columns", "statstamp"],
    "obj_code": ["object_name", "object_type"],
    "obj_source": ["object_name", "object_type", "colid", "text_hex"],
}


def content(side):
    return {
        "inst_config": INST_R1 if side == 1 else INST_R2,
        "db_size": DB_SIZE_R1 if side == 1 else DB_SIZE_R2,
        "db_options": DB_OPTIONS_R1 if side == 1 else DB_OPTIONS_R2,
        "obj_tables": tables(side),
        "obj_indexes": indexes(side),
        "obj_code": obj_code(side),
        "obj_source": obj_source(side),
    }


def write_fixtures(out_dir):
    os.makedirs(out_dir, exist_ok=True)
    for side in (1, 2):
        for module, rows in content(side).items():
            path = os.path.join(out_dir, f"r{side}_{module}.csv")
            with open(path, "w", encoding="utf-8", newline="") as fh:
                fh.write("|".join(HEADERS[module]) + "\n")
                for row in rows:
                    fh.write("|".join(row) + "\n")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    write_fixtures(sys.argv[1])
    print(f"CSV generes dans {sys.argv[1]}")

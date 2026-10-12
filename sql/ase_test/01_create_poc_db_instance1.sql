/* ==========================================================================
   POC compare ASE - Base de test pour l'INSTANCE 1
   Cible   : SAP ASE 16.0 (Developer Edition)
   Base    : poc_db
   Usage   : isql -S <INSTANCE_1> -U sa -i 01_create_poc_db_instance1.sql -o 01.log
   Note    : commentaires sans accent (charset ASE). A executer avec sa.

   ATTENTION : ce script SUPPRIME la base poc_db si elle existe deja.

   Ecarts volontaires par rapport a 02_create_poc_db_instance2.sql :
     inst_config : deadlock retries = 5, print deadlock information = 0
     db_size     : data 100 MB, log 40 MB
     db_options  : select into/bulkcopy/pllsort
     obj_tables  : customers.email varchar(100), customers.phone nullable,
                   orders.total_amount numeric(12,2), order_items.discount (seul ici),
                   table tmp_import (seule ici)
     obj_indexes : idx_orders_date (seul ici), pk_products clustered,
                   uq_customers_email unique, update statistics sur customers
     obj_code    : sp_purge_orders, trg_customers_upd (seuls ici)
     obj_source  : sp_get_customer, sp_calc_order_total (TVA 1.20),
                   v_orders_summary, trg_orders_audit
   ========================================================================== */

/* --------------------------------------------------------------------------
   0. PARAMETRES A ADAPTER : chemin des devices sur la VM ASE
   -------------------------------------------------------------------------- */
use master
go

if not exists (select 1 from master..sysdevices where name = 'poc_data')
begin
    disk init name = 'poc_data', physname = '/opt/sap/data/poc_data.dat', size = '200M'
end
go

if not exists (select 1 from master..sysdevices where name = 'poc_log')
begin
    disk init name = 'poc_log', physname = '/opt/sap/data/poc_log.dat', size = '100M'
end
go

/* --------------------------------------------------------------------------
   1. MODULE inst_config : parametres d'instance (dynamiques)
   -------------------------------------------------------------------------- */
sp_configure "deadlock retries", 5
go
sp_configure "print deadlock information", 0
go

/* --------------------------------------------------------------------------
   2. MODULES db_size et db_options : creation de la base
   -------------------------------------------------------------------------- */
if exists (select 1 from master..sysdatabases where name = 'poc_db')
begin
    drop database poc_db
end
go

create database poc_db on poc_data = 100 log on poc_log = 40
go

sp_dboption poc_db, "select into/bulkcopy/pllsort", true
go

use poc_db
go
checkpoint
go

/* --------------------------------------------------------------------------
   3. MODULE obj_tables : tables
   -------------------------------------------------------------------------- */
create table customers (
    customer_id  int          identity not null,
    first_name   varchar(50)  not null,
    last_name    varchar(50)  not null,
    email        varchar(100) null,
    phone        varchar(20)  null,
    created_at   datetime     default getdate() not null,
    constraint pk_customers primary key clustered (customer_id)
)
go

create table products (
    product_id   int           identity not null,
    label        varchar(100)  not null,
    unit_price   numeric(10,2) not null,
    constraint pk_products primary key clustered (product_id)
)
go

create table orders (
    order_id      int           identity not null,
    customer_id   int           not null,
    order_date    datetime      not null,
    total_amount  numeric(12,2) not null,
    constraint pk_orders primary key clustered (order_id)
)
go

create table order_items (
    order_item_id int           identity not null,
    order_id      int           not null,
    product_id    int           not null,
    quantity      int           not null,
    discount      numeric(5,2)  null,
    constraint pk_order_items primary key clustered (order_item_id)
)
go

create table audit_log (
    log_id       int          identity not null,
    table_name   varchar(30)  not null,
    action_type  char(3)      not null,
    changed_at   datetime     default getdate() not null,
    constraint pk_audit_log primary key clustered (log_id)
)
go

/* table presente uniquement dans la base 1 */
create table tmp_import (
    import_id    int           not null,
    payload      varchar(255)  null
)
go

/* --------------------------------------------------------------------------
   4. Jeu de donnees minimal (avant creation des triggers)
   -------------------------------------------------------------------------- */
insert customers (first_name, last_name, email, phone) values ('Alice', 'Martin', 'alice.martin@example.com', '0102030405')
insert customers (first_name, last_name, email, phone) values ('Bruno', 'Durand', 'bruno.durand@example.com', '0102030406')
insert customers (first_name, last_name, email, phone) values ('Chloe', 'Bernard', 'chloe.bernard@example.com', null)
go

insert products (label, unit_price) values ('Clavier', 29.90)
insert products (label, unit_price) values ('Souris', 14.50)
insert products (label, unit_price) values ('Ecran 24', 149.00)
go

insert orders (customer_id, order_date, total_amount) values (1, '20260105', 44.40)
insert orders (customer_id, order_date, total_amount) values (2, '20260210', 149.00)
insert orders (customer_id, order_date, total_amount) values (1, '20260315', 29.90)
go

insert order_items (order_id, product_id, quantity, discount) values (1, 1, 1, 0)
insert order_items (order_id, product_id, quantity, discount) values (1, 2, 1, 0)
insert order_items (order_id, product_id, quantity, discount) values (2, 3, 1, 5.00)
insert order_items (order_id, product_id, quantity, discount) values (3, 1, 1, null)
go

insert tmp_import (import_id, payload) values (1, 'donnee temporaire')
go

/* --------------------------------------------------------------------------
   5. MODULE obj_indexes : index
   -------------------------------------------------------------------------- */
create nonclustered index idx_customers_name on customers (last_name, first_name)
go
create unique nonclustered index uq_customers_email on customers (email)
go
create nonclustered index idx_order_items_order on order_items (order_id)
go
/* index present uniquement dans la base 1 */
create nonclustered index idx_orders_date on orders (order_date)
go

/* --------------------------------------------------------------------------
   6. MODULES obj_code et obj_source : vues, procedures, triggers
   -------------------------------------------------------------------------- */

/* --- vues --- */
create view v_orders_summary as
    select o.order_id, c.last_name, o.order_date, o.total_amount
    from orders o, customers c
    where o.customer_id = c.customer_id
go

/* --- procedures --- */

/* source different entre les deux bases */
create procedure sp_get_customer @customer_id int
as
begin
    select customer_id, first_name, last_name, email, phone
    from customers
    where customer_id = @customer_id
end
go

/* temoin : source identique dans les deux bases */
create procedure sp_list_products
as
begin
    select product_id, label, unit_price
    from products
    order by label
end
go

/* code long : le texte est stocke sur plusieurs lignes de syscomments (255 car.)
   l'ecart se situe dans la derniere partie du code */
create procedure sp_calc_order_total @order_id int
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

    /* taux de TVA : 1.20 dans la base 1 */
    select @total = @total * 1.20

    select @order_id as order_id, @total as total_ttc
end
go

/* procedure presente uniquement dans la base 1 */
create procedure sp_purge_orders
as
begin
    delete from orders
    where order_date < dateadd(yy, -3, getdate())
end
go

/* --- triggers --- */

/* source different entre les deux bases */
create trigger trg_orders_audit on orders
for insert, update
as
begin
    insert audit_log (table_name, action_type) values ('orders', 'IU')
end
go

/* trigger present uniquement dans la base 1 */
create trigger trg_customers_upd on customers
for update
as
begin
    insert audit_log (table_name, action_type) values ('customers', 'U')
end
go

/* --------------------------------------------------------------------------
   7. MODULE obj_indexes : date de statistiques (bruit volontaire)
      Uniquement dans la base 1
   -------------------------------------------------------------------------- */
update statistics customers
go

checkpoint
go

/* --------------------------------------------------------------------------
   8. Controle : objets crees dans poc_db
   -------------------------------------------------------------------------- */
select type, name from sysobjects where type in ('U', 'V', 'P', 'TR') order by type, name
go

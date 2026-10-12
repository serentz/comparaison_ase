/* ==========================================================================
   POC compare ASE - Base de test pour l'INSTANCE 2
   Cible   : SAP ASE 16.0 (Developer Edition)
   Base    : poc_db
   Usage   : isql -S <INSTANCE_2> -U sa -i 02_create_poc_db_instance2.sql -o 02.log
   Note    : commentaires sans accent (charset ASE). A executer avec sa.

   ATTENTION : ce script SUPPRIME la base poc_db si elle existe deja.

   Ecarts volontaires par rapport a 01_create_poc_db_instance1.sql :
     inst_config : deadlock retries = 10, print deadlock information = 1
     db_size     : data 120 MB, log 50 MB
     db_options  : trunc log on chkpt, abort tran on log full
     obj_tables  : customers.email varchar(150), customers.phone not null,
                   orders.total_amount numeric(14,2), products.barcode (seul ici),
                   table archive_orders (seule ici)
     obj_indexes : idx_orders_customer (seul ici), pk_products nonclustered,
                   uq_customers_email non unique, pas d'update statistics
     obj_code    : sp_archive_orders, v_customer_orders (seuls ici)
     obj_source  : sp_get_customer, sp_calc_order_total (TVA 1.21),
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
sp_configure "deadlock retries", 10
go
sp_configure "print deadlock information", 1
go

/* --------------------------------------------------------------------------
   2. MODULES db_size et db_options : creation de la base
   -------------------------------------------------------------------------- */
if exists (select 1 from master..sysdatabases where name = 'poc_db')
begin
    drop database poc_db
end
go

create database poc_db on poc_data = 120 log on poc_log = 50
go

sp_dboption poc_db, "trunc log on chkpt", true
go
sp_dboption poc_db, "abort tran on log full", true
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
    email        varchar(150) null,
    phone        varchar(20)  default '' not null,
    created_at   datetime     default getdate() not null,
    constraint pk_customers primary key clustered (customer_id)
)
go

create table products (
    product_id   int           identity not null,
    label        varchar(100)  not null,
    unit_price   numeric(10,2) not null,
    barcode      varchar(20)   null,
    constraint pk_products primary key nonclustered (product_id)
)
go

create table orders (
    order_id      int           identity not null,
    customer_id   int           not null,
    order_date    datetime      not null,
    total_amount  numeric(14,2) not null,
    constraint pk_orders primary key clustered (order_id)
)
go

create table order_items (
    order_item_id int           identity not null,
    order_id      int           not null,
    product_id    int           not null,
    quantity      int           not null,
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

/* table presente uniquement dans la base 2 */
create table archive_orders (
    order_id     int          not null,
    archived_at  datetime     not null
)
go

/* --------------------------------------------------------------------------
   4. Jeu de donnees minimal (avant creation des triggers)
   -------------------------------------------------------------------------- */
insert customers (first_name, last_name, email, phone) values ('Alice', 'Martin', 'alice.martin@example.com', '0102030405')
insert customers (first_name, last_name, email, phone) values ('Bruno', 'Durand', 'bruno.durand@example.com', '0102030406')
insert customers (first_name, last_name, email, phone) values ('Chloe', 'Bernard', 'chloe.bernard@example.com', '0102030407')
go

insert products (label, unit_price, barcode) values ('Clavier', 29.90, '3760000000011')
insert products (label, unit_price, barcode) values ('Souris', 14.50, '3760000000028')
insert products (label, unit_price, barcode) values ('Ecran 24', 149.00, '3760000000035')
go

insert orders (customer_id, order_date, total_amount) values (1, '20260105', 44.40)
insert orders (customer_id, order_date, total_amount) values (2, '20260210', 149.00)
insert orders (customer_id, order_date, total_amount) values (1, '20260315', 29.90)
go

insert order_items (order_id, product_id, quantity) values (1, 1, 1)
insert order_items (order_id, product_id, quantity) values (1, 2, 1)
insert order_items (order_id, product_id, quantity) values (2, 3, 1)
insert order_items (order_id, product_id, quantity) values (3, 1, 1)
go

/* --------------------------------------------------------------------------
   5. MODULE obj_indexes : index
   -------------------------------------------------------------------------- */
create nonclustered index idx_customers_name on customers (last_name, first_name)
go
/* meme nom que dans la base 1 mais NON unique */
create nonclustered index uq_customers_email on customers (email)
go
create nonclustered index idx_order_items_order on order_items (order_id)
go
/* index present uniquement dans la base 2 */
create nonclustered index idx_orders_customer on orders (customer_id)
go

/* --------------------------------------------------------------------------
   6. MODULES obj_code et obj_source : vues, procedures, triggers
   -------------------------------------------------------------------------- */

/* --- vues --- */

/* source different entre les deux bases */
create view v_orders_summary as
    select o.order_id, c.last_name, o.order_date, o.total_amount
    from orders o, customers c
    where o.customer_id = c.customer_id
      and o.total_amount > 0
go

/* vue presente uniquement dans la base 2 */
create view v_customer_orders as
    select c.customer_id, c.last_name, count(o.order_id) as nb_orders
    from customers c, orders o
    where c.customer_id = o.customer_id
    group by c.customer_id, c.last_name
go

/* --- procedures --- */

/* source different entre les deux bases */
create procedure sp_get_customer @customer_id int
as
begin
    select customer_id, first_name, last_name, email, phone, created_at
    from customers
    where customer_id = @customer_id
    order by last_name
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

    /* taux de TVA : 1.21 dans la base 2 */
    select @total = @total * 1.21

    select @order_id as order_id, @total as total_ttc
end
go

/* procedure presente uniquement dans la base 2 */
create procedure sp_archive_orders
as
begin
    insert archive_orders (order_id, archived_at)
    select order_id, getdate()
    from orders
    where order_date < dateadd(yy, -1, getdate())
end
go

/* --- triggers --- */

/* source different entre les deux bases */
create trigger trg_orders_audit on orders
for insert, update, delete
as
begin
    insert audit_log (table_name, action_type) values ('orders', 'IUD')
end
go

/* --------------------------------------------------------------------------
   7. Pas d'update statistics dans la base 2 (ecart de statstamp volontaire)
   -------------------------------------------------------------------------- */
checkpoint
go

/* --------------------------------------------------------------------------
   8. Controle : objets crees dans poc_db
   -------------------------------------------------------------------------- */
select type, name from sysobjects where type in ('U', 'V', 'P', 'TR') order by type, name
go

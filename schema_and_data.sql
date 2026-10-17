-- ============================================================
-- Week 6 | SQL Data Engineering Pipeline | MySQL 8.0
-- File 1/2: schema + seed data   (run first)
-- ============================================================
DROP DATABASE IF EXISTS sql_de_pipeline;
CREATE DATABASE sql_de_pipeline CHARACTER SET utf8mb4;
USE sql_de_pipeline;

-- ---------- Dimensions ----------
CREATE TABLE dim_customer (
    customer_id   INT PRIMARY KEY,
    customer_name VARCHAR(100) NOT NULL,
    city          VARCHAR(50),
    email         VARCHAR(100),
    updated_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
                  ON UPDATE CURRENT_TIMESTAMP
);

CREATE TABLE dim_product (
    product_id   INT PRIMARY KEY,
    product_name VARCHAR(100) NOT NULL,
    category     VARCHAR(50),
    price        DECIMAL(10,2) NOT NULL
);

-- ---------- Staging ----------
-- Customer feed (source of the UPSERT)
CREATE TABLE stg_customer (
    customer_id   INT PRIMARY KEY,
    customer_name VARCHAR(100) NOT NULL,
    city          VARCHAR(50),
    email         VARCHAR(100)
);

-- Raw CSV landing zone: everything VARCHAR so bad rows never fail the load
CREATE TABLE stg_sales (
    sale_id     VARCHAR(30),
    sale_date   VARCHAR(30),
    customer_id VARCHAR(30),
    product_id  VARCHAR(30),
    quantity    VARCHAR(30),
    unit_price  VARCHAR(30)
);

-- ---------- Fact (RANGE partitioned by year) ----------
-- MySQL rule: every unique key (incl. PK) must contain the partition column
CREATE TABLE fact_sales (
    sale_id     INT           NOT NULL,
    sale_date   DATE          NOT NULL,
    customer_id INT           NOT NULL,
    product_id  INT           NOT NULL,
    quantity    INT           NOT NULL,
    unit_price  DECIMAL(10,2) NOT NULL,
    PRIMARY KEY (sale_id, sale_date)
)
PARTITION BY RANGE (YEAR(sale_date)) (
    PARTITION p2024   VALUES LESS THAN (2025),
    PARTITION p2025   VALUES LESS THAN (2026),
    PARTITION p2026   VALUES LESS THAN (2027),
    PARTITION p_future VALUES LESS THAN MAXVALUE
);

-- ---------- Seed data ----------
INSERT INTO dim_customer (customer_id, customer_name, city, email) VALUES
(1, 'Aarav Sharma', 'Bengaluru', 'aarav@example.com'),
(2, 'Priya Rao',    'Mysuru',    'priya@example.com'),
(3, 'Rahul Kumar',  'Chennai',   'rahul@example.com'),
(4, 'Sneha Patil',  'Pune',      'sneha@example.com');

INSERT INTO dim_product VALUES
(101, 'Laptop',       'Electronics', 55000.00),
(102, 'Smartphone',   'Electronics', 25000.00),
(103, 'Office Chair', 'Furniture',    7500.00),
(104, 'Desk',         'Furniture',   12000.00);

-- Incoming customer changes: 1 unchanged, 2 changed, 5 brand new
INSERT INTO stg_customer VALUES
(1, 'Aarav Sharma', 'Bengaluru', 'aarav@example.com'),
(2, 'Priya Rao',    'Hubballi',  'priya.new@example.com'),
(5, 'Kiran Reddy',  'Hyderabad', 'kiran@example.com');

INSERT INTO fact_sales VALUES
(1, '2024-06-15', 1, 101, 1, 55000.00),
(2, '2024-11-20', 2, 102, 2, 25000.00),
(3, '2025-01-10', 3, 103, 1,  7500.00),
(4, '2025-03-18', 1, 102, 1, 25000.00),
(5, '2025-07-22', 4, 104, 2, 12000.00),
(6, '2026-02-12', 2, 101, 1, 55000.00);

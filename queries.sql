-- ============================================================
-- Week 6 | SQL Data Engineering Pipeline | MySQL 8.0
-- File 2/2: pipeline queries   (run after schema_and_data.sql)
-- Run from the project folder:
--   mysql --local-infile=1 -u root -p < queries.sql
-- ============================================================
USE sql_de_pipeline;

-- ============================================================
-- SECTION 1: DIMENSION UPSERT  (SCD Type 1 - overwrite)
-- ============================================================
-- Q1. Before
SELECT customer_id, customer_name, city, email FROM dim_customer ORDER BY customer_id;

-- Q2. UPSERT: insert new keys, overwrite changed ones
--     Row-count: 1 = inserted, 2 = updated, 0 = unchanged
INSERT INTO dim_customer (customer_id, customer_name, city, email)
SELECT s.customer_id, s.customer_name, s.city, s.email
FROM stg_customer AS s
ON DUPLICATE KEY UPDATE
    customer_name = s.customer_name,
    city          = s.city,
    email         = s.email;

-- Q3. After  (expect: 2 -> Hubballi/new email, 5 inserted, 1 untouched)
SELECT customer_id, customer_name, city, email FROM dim_customer ORDER BY customer_id;

-- ============================================================
-- SECTION 2: PARTITIONING
-- ============================================================
-- Q4. Rows per partition
SELECT PARTITION_NAME, PARTITION_DESCRIPTION AS less_than_year, TABLE_ROWS
FROM INFORMATION_SCHEMA.PARTITIONS
WHERE TABLE_SCHEMA = 'sql_de_pipeline' AND TABLE_NAME = 'fact_sales'
ORDER BY PARTITION_ORDINAL_POSITION;

-- Q5. Sales per year
SELECT YEAR(sale_date) AS sales_year, COUNT(*) AS total_sales,
       SUM(quantity * unit_price) AS revenue
FROM fact_sales
GROUP BY YEAR(sale_date)
ORDER BY sales_year;

-- Q6. Partition pruning: "partitions" column must show only p2025
--     Filter on the raw sale_date column with a range; wrapping it in a
--     function (e.g. MONTH(sale_date)) would block pruning on older versions.
EXPLAIN
SELECT * FROM fact_sales
WHERE sale_date >= '2025-01-01' AND sale_date < '2026-01-01';

-- ============================================================
-- SECTION 3: BULK CSV LOAD  (staging -> validate -> fact)
-- ============================================================
-- Q7. Reset staging so the script is re-runnable
TRUNCATE TABLE stg_sales;

-- Q8. Bulk load. Path is relative to where you started the mysql client.
--     In Workbench use an absolute path with forward slashes, e.g.
--     'D:/DataGrokr/Week6/sales.csv'
--     CSV has Windows (\r\n) endings on Windows -> last column cleaned via SET.
LOAD DATA LOCAL INFILE 'sales.csv'
INTO TABLE stg_sales
FIELDS TERMINATED BY ','
LINES  TERMINATED BY '\n'
IGNORE 1 LINES
(sale_id, sale_date, customer_id, product_id, quantity, @unit_price)
SET unit_price = TRIM(REPLACE(@unit_price, '\r', ''));

-- Q9. Staged row count
SELECT COUNT(*) AS staged_rows FROM stg_sales;

-- Q10. Pre-load validation report: why each staged row would be rejected
--      (run BEFORE the insert so "already exists" is detectable)
SELECT s.*,
       CASE
         WHEN s.sale_id     NOT REGEXP '^[0-9]+$'                     THEN 'bad sale_id'
         WHEN s.customer_id NOT REGEXP '^[0-9]+$'                     THEN 'bad customer_id'
         WHEN s.product_id  NOT REGEXP '^[0-9]+$'                     THEN 'bad product_id'
         WHEN s.quantity    NOT REGEXP '^[0-9]+$'
              OR CAST(s.quantity AS UNSIGNED) = 0                     THEN 'bad quantity'
         WHEN s.unit_price  NOT REGEXP '^[0-9]+(\\.[0-9]{1,2})?$'      THEN 'bad unit_price'
         WHEN STR_TO_DATE(s.sale_date, '%Y-%m-%d') IS NULL            THEN 'bad date'
         WHEN NOT EXISTS (SELECT 1 FROM dim_customer c
                          WHERE c.customer_id = CAST(s.customer_id AS UNSIGNED)) THEN 'unknown customer'
         WHEN NOT EXISTS (SELECT 1 FROM dim_product p
                          WHERE p.product_id = CAST(s.product_id AS UNSIGNED))   THEN 'unknown product'
         WHEN EXISTS (SELECT 1 FROM fact_sales f
                      WHERE f.sale_id   = CAST(s.sale_id AS UNSIGNED)
                        AND f.sale_date = CAST(s.sale_date AS DATE))             THEN 'duplicate (already loaded)'
       END AS reject_reason
FROM stg_sales AS s
HAVING reject_reason IS NOT NULL;

-- Q11. Load only valid, new rows into the partitioned fact table
INSERT INTO fact_sales (sale_id, sale_date, customer_id, product_id, quantity, unit_price)
SELECT CAST(s.sale_id AS UNSIGNED),
       CAST(s.sale_date AS DATE),
       CAST(s.customer_id AS UNSIGNED),
       CAST(s.product_id AS UNSIGNED),
       CAST(s.quantity AS UNSIGNED),
       CAST(s.unit_price AS DECIMAL(10,2))
FROM stg_sales AS s
WHERE s.sale_id     REGEXP '^[0-9]+$'
  AND s.customer_id REGEXP '^[0-9]+$'
  AND s.product_id  REGEXP '^[0-9]+$'
  AND s.quantity    REGEXP '^[0-9]+$' AND CAST(s.quantity AS UNSIGNED) > 0
  AND s.unit_price  REGEXP '^[0-9]+(\\.[0-9]{1,2})?$'
  AND STR_TO_DATE(s.sale_date, '%Y-%m-%d') IS NOT NULL
  AND EXISTS (SELECT 1 FROM dim_customer c WHERE c.customer_id = CAST(s.customer_id AS UNSIGNED))
  AND EXISTS (SELECT 1 FROM dim_product  p WHERE p.product_id  = CAST(s.product_id  AS UNSIGNED))
  AND NOT EXISTS (
        SELECT 1 FROM fact_sales AS f
        WHERE f.sale_id   = CAST(s.sale_id AS UNSIGNED)
          AND f.sale_date = CAST(s.sale_date AS DATE)
  );

-- Q12. Verify (expect 11 rows: 6 original + 5 new)
SELECT COUNT(*) AS total_sales FROM fact_sales;
SELECT * FROM fact_sales WHERE sale_id BETWEEN 7 AND 11 ORDER BY sale_id;

-- ============================================================
-- SECTION 4: INDEXING + EXPLAIN
-- ============================================================
-- Q13. BEFORE index: note type / key / rows
EXPLAIN
SELECT sale_id, sale_date, customer_id, quantity, unit_price
FROM fact_sales
WHERE sale_date >= '2025-01-01' AND sale_date < '2026-01-01' AND customer_id = 3;

-- Q14. Composite index: equality column first (customer_id), range column
--      second (sale_date) so MySQL can seek to the customer then range-scan dates.
CREATE INDEX idx_sales_customer_date ON fact_sales (customer_id, sale_date);

-- Q15. AFTER index: key = idx_sales_customer_date, fewer rows, partitions = p2025
EXPLAIN
SELECT sale_id, sale_date, customer_id, quantity, unit_price
FROM fact_sales
WHERE sale_date >= '2025-01-01' AND sale_date < '2026-01-01' AND customer_id = 3;

-- Q16. EXPLAIN ANALYZE = actually runs it; shows real time and row counts
EXPLAIN ANALYZE
SELECT customer_id, SUM(quantity * unit_price) AS spend
FROM fact_sales
WHERE customer_id = 2 AND sale_date >= '2025-01-01'
GROUP BY customer_id;

-- Q17. Indexes on the table
SHOW INDEX FROM fact_sales;

-- ============================================================
-- SECTION 5: UPDATE / DELETE inside a transaction (ACID)
-- ============================================================
START TRANSACTION;

-- Q18. Correct a price
UPDATE fact_sales SET unit_price = 24000.00 WHERE sale_id = 4 AND sale_date = '2025-03-18';

-- Q19. Remove a test/bad record
DELETE FROM fact_sales WHERE sale_id = 11 AND sale_date = '2026-05-19';

-- Q20. Inspect inside the transaction, then undo to demonstrate atomicity
SELECT sale_id, unit_price FROM fact_sales WHERE sale_id IN (4, 11);
ROLLBACK;

-- Q21. Same checks after ROLLBACK (changes gone: price 25000, row 11 back)
SELECT sale_id, unit_price FROM fact_sales WHERE sale_id IN (4, 11);

-- Q22. Isolation level in use (MySQL InnoDB default = REPEATABLE-READ)
SELECT @@transaction_isolation AS isolation_level;

-- ============================================================
-- SECTION 6: FINAL SALES REPORT
-- ============================================================
-- Q23. Revenue by year x category with customer city
SELECT YEAR(f.sale_date)               AS sales_year,
       p.category,
       COUNT(*)                        AS orders,
       SUM(f.quantity)                 AS units,
       SUM(f.quantity * f.unit_price)  AS revenue
FROM fact_sales   AS f
JOIN dim_product  AS p ON p.product_id  = f.product_id
JOIN dim_customer AS c ON c.customer_id = f.customer_id
GROUP BY YEAR(f.sale_date), p.category
ORDER BY sales_year, revenue DESC;

-- Q24. Top customers
SELECT c.customer_id, c.customer_name, c.city,
       COUNT(*) AS orders,
       SUM(f.quantity * f.unit_price) AS total_spend,
       RANK() OVER (ORDER BY SUM(f.quantity * f.unit_price) DESC) AS spend_rank
FROM fact_sales f
JOIN dim_customer c ON c.customer_id = f.customer_id
GROUP BY c.customer_id, c.customer_name, c.city
ORDER BY spend_rank;

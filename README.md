# Week 6 – SQL Data Engineering Pipeline (MySQL 8.0)

E-commerce mini pipeline: **staging → dimension UPSERT → validated bulk load → partitioned fact table → indexing → EXPLAIN → ACID demo → report**.

## Pipeline

```
sales.csv ──LOAD DATA LOCAL INFILE──► stg_sales (all VARCHAR)
                                         │ validate (format, FK, duplicates)
stg_customer ──UPSERT──► dim_customer    ▼
                                    fact_sales  (RANGE-partitioned by YEAR)
                                         │ composite index + EXPLAIN / EXPLAIN ANALYZE
                                         ▼
                                    sales report
```

## Files

| File | Purpose |
|---|---|
| `schema_and_data.sql` | Creates DB, tables, partitions, seed data |
| `queries.sql` | 24 numbered queries in 6 sections |
| `sales.csv` | 8 rows: 5 valid new, 1 duplicate, 1 unknown product, 1 bad quantity |

## Tables

| Table | Role |
|---|---|
| `dim_customer` | Customer dimension (SCD Type 1) |
| `dim_product` | Product dimension |
| `stg_customer` | Incoming customer changes |
| `stg_sales` | Raw CSV landing zone |
| `fact_sales` | Sales facts, PK `(sale_id, sale_date)`, partitions `p2024 / p2025 / p2026 / p_future` |

## Concepts → where

| Concept | Query | Key SQL |
|---|---|---|
| UPSERT | Q2 | `INSERT … SELECT … ON DUPLICATE KEY UPDATE` |
| Range partitioning | Q4–Q6 | `PARTITION BY RANGE (YEAR(sale_date))`, `EXPLAIN` → `partitions = p2025` |
| Bulk load | Q7–Q9 | `LOAD DATA LOCAL INFILE … IGNORE 1 LINES` |
| Data validation | Q10–Q11 | regex + `STR_TO_DATE` + FK `EXISTS` + `NOT EXISTS` dedupe |
| Composite index | Q14 | `(customer_id, sale_date)` |
| Execution plans | Q13, Q15, Q16 | `EXPLAIN`, `EXPLAIN ANALYZE` |
| ACID / rollback | Q18–Q22 | `START TRANSACTION … ROLLBACK`, `@@transaction_isolation` |
| Reporting | Q23–Q24 | joins, `GROUP BY`, `RANK() OVER` |

## Run

```bash
cd week6_sql_de_pipeline
mysql --local-infile=1 -u root -p < schema_and_data.sql
mysql --local-infile=1 -u root -p < queries.sql
```

Workbench: run `schema_and_data.sql`, then in `queries.sql` change `'sales.csv'` to an absolute path with forward slashes (`'D:/DataGrokr/Week6/sales.csv'`) and run the queries in order.

If you get `Loading local data is disabled`:

```sql
SET GLOBAL local_infile = 1;
```

and enable `OPT_LOCAL_INFILE=1` in the Workbench connection (Advanced → Others).

## Expected results

| Check | Expected |
|---|---|
| Q3 customers | 5 rows; id 2 → Hubballi / `priya.new@example.com`; id 5 inserted |
| Q4 partitions | p2024=2, p2025=3, p2026=1, p_future=0 |
| Q6 EXPLAIN | `partitions = p2025` only |
| Q10 rejects | sale 6 duplicate, 12 unknown product, 13 bad quantity |
| Q12 total | 11 rows |
| Q13 → Q15 | `type ALL / key NULL` → `type range / key idx_sales_customer_date` |
| Q20 → Q21 | price 24000 / row 11 gone → rolled back to 25000 / row 11 back |
| Q22 | `REPEATABLE-READ` |

## Design notes

| Decision | Reason |
|---|---|
| `sale_date` in the PK | MySQL requires every unique key to include the partition column |
| Staging table is all `VARCHAR` | Bad rows land safely and are rejected in SQL instead of aborting the load |
| `customer_id` first in the index | Equality column before range column lets MySQL seek, then range-scan |
| Regular staging table (not `TEMPORARY`) | Works across connections; `TRUNCATE` makes the script re-runnable |
| Last CSV column cleaned with `REPLACE(@col,'\r','')` | Handles Windows line endings |

## Tech

MySQL 8.0 · MySQL Workbench / CLI · SQL · CSV · Git

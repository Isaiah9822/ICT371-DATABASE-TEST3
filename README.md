# ICT371 Advanced Database: Final Paper

**Student:** Nicholas | Mulungushi University
**Database:** PostgreSQL

Solutions to the 10-question ICT371 paper. Each file covers parts (a) to (g):
(a) tables and seed data, (b) function, (c) procedure, (d) trigger, (e) view, (f) index with EXPLAIN, (g) scheduled job.

## Questions

| Q | Topic | File |
|---|-------|------|
| 1 | Pharmacy Stock and Daily Sales | [q01_pharmacy.sql](q01_pharmacy.sql) |
| 2 | University Fee Payments | [q02_fee_payments.sql](q02_fee_payments.sql) |
| 3 | Library Returns and Overdue Fines | [q03_library_fines.sql](q03_library_fines.sql) |
| 4 | Clinic Appointment Scheduling | [q04_clinic_appointments.sql](q04_clinic_appointments.sql) |
| 5 | Hostel Room Allocation | [q05_hostel_allocation.sql](q05_hostel_allocation.sql) |
| 6 | Monthly Payroll Processing | [q06_payroll.sql](q06_payroll.sql) |
| 7 | Water Meter Readings and Billing | [q07_water_billing.sql](q07_water_billing.sql) |
| 8 | Transport Fleet Maintenance | [q08_fleet_maintenance.sql](q08_fleet_maintenance.sql) |
| 9 | Farmer Cooperative Maize Deliveries | [q09_maize_deliveries.sql](q09_maize_deliveries.sql) |
| 10 | Scholarship Application Assessment | [q10_scholarship.sql](q10_scholarship.sql) |

## How to run

Open a file in pgAdmin or psql and run it, or from the terminal:

```bash
psql -d your_database -f q01_pharmacy.sql
```

Each file drops and recreates its own tables at the top, so it can be rerun safely.

Questions 2, 5 and 10 all use a table called `students`. Run one question at a time (run it, take your screenshots, then move to the next), because the later file replaces the earlier one's tables.

## Scheduled jobs

Part (g) uses the `pg_cron` extension. To enable it:

1. Add `shared_preload_libraries = 'pg_cron'` to `postgresql.conf` and restart PostgreSQL.
2. Run `CREATE EXTENSION IF NOT EXISTS pg_cron;`

If `pg_cron` is not installed, the `cron.schedule` line in a file will fail. The rest of the file still runs.

## Notes

- Error cases are tested inside `DO` blocks, so a rejected call prints a message and the script keeps running.
- The `EXPLAIN` sections use `SET enable_seqscan = off` because the seed tables are tiny and PostgreSQL would otherwise choose a sequential scan.

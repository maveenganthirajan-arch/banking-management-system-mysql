# Banking Management System using MySQL

A database project that models core banking operations using MySQL 8.0+ and InnoDB.

## Project Overview

This project demonstrates relational database design and SQL techniques for managing customers, bank accounts, transactions, transfers, and audit records.

## Features

- Customer and account management
- Deposit and withdrawal operations
- Account-to-account transfers
- Transaction history and statement queries
- Reporting and analytics views
- Stored procedures and SQL functions
- Triggers, constraints, and indexes
- Transaction handling with `COMMIT` and `ROLLBACK`
- Automated test procedures and integrity checks

## Database Structure

The project defines seven main tables:

- `customers`
- `accounts`
- `transactions`
- `transaction_entries`
- `transfers`
- `audit_logs`
- `users`

It also includes stored procedures, functions, triggers, and views for operations, auditing, and reporting.

## Requirements

- MySQL 8.0 or later
- A MySQL client such as MySQL Workbench or the MySQL command-line client

## How to Run

> **Warning:** The SQL script starts with `DROP DATABASE IF EXISTS bank_db;`. Running it will delete an existing database named `bank_db`. Back up any important data before executing it.

From a terminal, run:

```bash
mysql -u root -p < Banking_system_project_mysql.sql
```

Alternatively, open the SQL file in MySQL Workbench and execute it after reviewing the script.

## Notes

- Sample data in the script is intended to be fictional.
- This is an educational database project, not a production-ready banking application.
- Review and test the SQL in a safe local database before using it with any real data.

## Skills Demonstrated

`MySQL` · `SQL` · `Database Design` · `Stored Procedures` · `Triggers` · `Views` · `Transactions` · `Data Integrity` · `Reporting`

## License

No license has been specified yet. Add a license if you want to define how others may use, modify, and distribute this project.

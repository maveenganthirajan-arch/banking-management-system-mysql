/* =====================================================================
   BANKING & TRANSACTION MANAGEMENT SYSTEM  (MySQL 8.0+, InnoDB)
   ---------------------------------------------------------------------
   Follows the project blueprint:
     7 tables : customers, accounts, transactions, transaction_entries,
                transfers, audit_logs, users
     Modules  : 1 Customer/Account mgmt   2 Deposit/Withdraw
                3 Transfer (ACID)         4 History search
                5 Reports & analytics
     Advanced : joins, subqueries, stored procedures, transactions,
                COMMIT/ROLLBACK, triggers, views, constraints,
                window functions, indexes, row locking, idempotency
   Run:  mysql -u root -p < banking_system.sql
   All data is fictional.
   ===================================================================== */

DROP DATABASE IF EXISTS bank_db;
CREATE DATABASE bank_db CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE bank_db;

/* =====================================================================
   1. TABLES  (Phase 2)
   Money = DECIMAL(15,2) (never FLOAT). All tables InnoDB.
   ===================================================================== */

CREATE TABLE customers (
    customer_id  INT AUTO_INCREMENT PRIMARY KEY,
    full_name    VARCHAR(100) NOT NULL,
    email        VARCHAR(120) NOT NULL,
    phone        CHAR(10)     NOT NULL,
    address      VARCHAR(255),
    created_at   TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_customer_email UNIQUE (email),
    CONSTRAINT uq_customer_phone UNIQUE (phone),
    CONSTRAINT chk_customer_email CHECK (email LIKE '%_@_%._%'),
    CONSTRAINT chk_customer_phone CHECK (phone REGEXP '^[0-9]{10}$')
) ENGINE=InnoDB;

CREATE TABLE accounts (
    account_id      INT AUTO_INCREMENT PRIMARY KEY,
    customer_id     INT           NOT NULL,
    account_number  VARCHAR(16)   NOT NULL,
    account_type    ENUM('SAVINGS','CURRENT','SALARY') NOT NULL DEFAULT 'SAVINGS',
    balance         DECIMAL(15,2) NOT NULL DEFAULT 0.00,     -- cached current balance
    status          ENUM('ACTIVE','FROZEN','CLOSED')   NOT NULL DEFAULT 'ACTIVE',
    created_at      TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_account_number UNIQUE (account_number),
    CONSTRAINT chk_account_balance CHECK (balance >= 0),
    CONSTRAINT fk_accounts_customer FOREIGN KEY (customer_id)
        REFERENCES customers(customer_id) ON DELETE RESTRICT,
    INDEX idx_accounts_customer (customer_id)
) ENGINE=InnoDB;

-- Transaction HEADER (one row per business operation)
CREATE TABLE transactions (
    transaction_id    BIGINT AUTO_INCREMENT PRIMARY KEY,
    transaction_type  ENUM('DEPOSIT','WITHDRAWAL','TRANSFER') NOT NULL,
    amount            DECIMAL(15,2) NOT NULL,
    status            ENUM('PENDING','COMPLETED','FAILED')    NOT NULL DEFAULT 'PENDING',
    reference         VARCHAR(40)   NOT NULL,                 -- idempotency key
    created_at        TIMESTAMP(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    CONSTRAINT uq_txn_reference UNIQUE (reference),
    CONSTRAINT chk_txn_amount CHECK (amount > 0),
    INDEX idx_txn_created (created_at),
    INDEX idx_txn_type_status (transaction_type, status)
) ENGINE=InnoDB;

-- Debit / credit SIDES of every money movement
CREATE TABLE transaction_entries (
    entry_id        BIGINT AUTO_INCREMENT PRIMARY KEY,
    transaction_id  BIGINT        NOT NULL,
    account_id      INT           NOT NULL,
    entry_type      ENUM('DEBIT','CREDIT') NOT NULL,
    amount          DECIMAL(15,2) NOT NULL,
    balance_after   DECIMAL(15,2) NOT NULL,                   -- snapshot for statements
    CONSTRAINT chk_entry_amount CHECK (amount > 0),
    CONSTRAINT fk_entry_txn FOREIGN KEY (transaction_id)
        REFERENCES transactions(transaction_id) ON DELETE RESTRICT,
    CONSTRAINT fk_entry_acc FOREIGN KEY (account_id)
        REFERENCES accounts(account_id) ON DELETE RESTRICT,
    INDEX idx_entry_account (account_id, entry_id),
    INDEX idx_entry_txn (transaction_id)
) ENGINE=InnoDB;

-- Source and destination of a TRANSFER (0 or 1 per transaction)
CREATE TABLE transfers (
    transfer_id      BIGINT AUTO_INCREMENT PRIMARY KEY,
    transaction_id   BIGINT NOT NULL,
    from_account_id  INT    NOT NULL,
    to_account_id    INT    NOT NULL,
    CONSTRAINT uq_transfer_txn UNIQUE (transaction_id),
    CONSTRAINT chk_transfer_diff CHECK (from_account_id <> to_account_id),
    CONSTRAINT fk_transfer_txn  FOREIGN KEY (transaction_id)  REFERENCES transactions(transaction_id),
    CONSTRAINT fk_transfer_from FOREIGN KEY (from_account_id) REFERENCES accounts(account_id),
    CONSTRAINT fk_transfer_to   FOREIGN KEY (to_account_id)   REFERENCES accounts(account_id)
) ENGINE=InnoDB;

CREATE TABLE audit_logs (
    log_id       BIGINT AUTO_INCREMENT PRIMARY KEY,
    actor        VARCHAR(100) NOT NULL,
    action       VARCHAR(40)  NOT NULL,
    entity_type  VARCHAR(40)  NOT NULL,
    entity_id    BIGINT       NULL,
    details      JSON         NULL,
    created_at   TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    INDEX idx_audit_entity (entity_type, entity_id),
    INDEX idx_audit_action (action)
) ENGINE=InnoDB;

CREATE TABLE users (
    user_id        INT AUTO_INCREMENT PRIMARY KEY,
    username       VARCHAR(50)  NOT NULL,
    password_hash  CHAR(64)     NOT NULL,       -- demo: SHA2-256; use bcrypt/argon2 in a real app
    role           ENUM('ADMIN','TELLER','CUSTOMER') NOT NULL DEFAULT 'CUSTOMER',
    customer_id    INT NULL,
    CONSTRAINT uq_username UNIQUE (username),
    CONSTRAINT fk_users_customer FOREIGN KEY (customer_id) REFERENCES customers(customer_id)
) ENGINE=InnoDB;

/* =====================================================================
   2. FUNCTIONS
   ===================================================================== */
DELIMITER $$

CREATE FUNCTION fn_new_reference(p_prefix VARCHAR(6)) RETURNS VARCHAR(40)
NO SQL
BEGIN
    RETURN CONCAT(p_prefix, '-', UPPER(LEFT(REPLACE(UUID(), '-', ''), 20)));
END$$

-- 1 when total DEBITs = total CREDITs for a transaction
CREATE FUNCTION fn_entries_balanced(p_transaction_id BIGINT) RETURNS TINYINT
READS SQL DATA
BEGIN
    DECLARE v_debit  DECIMAL(15,2);
    DECLARE v_credit DECIMAL(15,2);
    SELECT COALESCE(SUM(CASE WHEN entry_type = 'DEBIT'  THEN amount END), 0),
           COALESCE(SUM(CASE WHEN entry_type = 'CREDIT' THEN amount END), 0)
      INTO v_debit, v_credit
      FROM transaction_entries WHERE transaction_id = p_transaction_id;
    RETURN (v_debit = v_credit AND v_debit > 0);
END$$

/* =====================================================================
   3. TRIGGERS  (Phase 7: auditing + integrity)
   ===================================================================== */

CREATE TRIGGER trg_customers_ai AFTER INSERT ON customers FOR EACH ROW
BEGIN
    INSERT INTO audit_logs(actor, action, entity_type, entity_id, details)
    VALUES (COALESCE(@app_user, USER()), 'CUSTOMER_CREATED', 'CUSTOMER', NEW.customer_id,
            JSON_OBJECT('full_name', NEW.full_name, 'email', NEW.email));
END$$

CREATE TRIGGER trg_customers_au AFTER UPDATE ON customers FOR EACH ROW
BEGIN
    INSERT INTO audit_logs(actor, action, entity_type, entity_id, details)
    VALUES (COALESCE(@app_user, USER()), 'CUSTOMER_UPDATED', 'CUSTOMER', OLD.customer_id,
            JSON_OBJECT('old_email', OLD.email, 'new_email', NEW.email,
                        'old_phone', OLD.phone, 'new_phone', NEW.phone,
                        'old_address', OLD.address, 'new_address', NEW.address));
END$$

CREATE TRIGGER trg_accounts_ai AFTER INSERT ON accounts FOR EACH ROW
BEGIN
    INSERT INTO audit_logs(actor, action, entity_type, entity_id, details)
    VALUES (COALESCE(@app_user, USER()), 'ACCOUNT_CREATED', 'ACCOUNT', NEW.account_id,
            JSON_OBJECT('customer_id', NEW.customer_id, 'type', NEW.account_type));
END$$

-- Closed accounts are final; closing requires a zero balance
CREATE TRIGGER trg_accounts_bu BEFORE UPDATE ON accounts FOR EACH ROW
BEGIN
    IF OLD.status = 'CLOSED' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Closed accounts cannot be modified';
    END IF;
    IF NEW.status = 'CLOSED' AND NEW.balance <> 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Account must have zero balance before closing';
    END IF;
END$$

CREATE TRIGGER trg_accounts_au AFTER UPDATE ON accounts FOR EACH ROW
BEGIN
    IF NOT (OLD.balance <=> NEW.balance AND OLD.status <=> NEW.status) THEN
        INSERT INTO audit_logs(actor, action, entity_type, entity_id, details)
        VALUES (COALESCE(@app_user, USER()),
                IF(OLD.status <> NEW.status, 'ACCOUNT_STATUS_CHANGED', 'BALANCE_CHANGED'),
                'ACCOUNT', OLD.account_id,
                JSON_OBJECT('old_balance', OLD.balance, 'new_balance', NEW.balance,
                            'old_status', OLD.status, 'new_status', NEW.status));
    END IF;
END$$

-- Transaction header: only PENDING -> COMPLETED/FAILED is allowed; nothing else may change
CREATE TRIGGER trg_txn_bu BEFORE UPDATE ON transactions FOR EACH ROW
BEGIN
    IF OLD.status <> 'PENDING'
       OR NEW.amount <> OLD.amount
       OR NEW.reference <> OLD.reference
       OR NEW.transaction_type <> OLD.transaction_type THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Transactions are immutable once completed';
    END IF;
END$$

CREATE TRIGGER trg_txn_au AFTER UPDATE ON transactions FOR EACH ROW
BEGIN
    IF OLD.status <> NEW.status THEN
        INSERT INTO audit_logs(actor, action, entity_type, entity_id, details)
        VALUES (COALESCE(@app_user, USER()), CONCAT('TXN_', NEW.status), 'TRANSACTION', NEW.transaction_id,
                JSON_OBJECT('type', NEW.transaction_type, 'amount', NEW.amount, 'reference', NEW.reference));
    END IF;
END$$

CREATE TRIGGER trg_txn_bd BEFORE DELETE ON transactions FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Transactions cannot be deleted';
END$$

-- Ledger entries are append-only
CREATE TRIGGER trg_entries_bu BEFORE UPDATE ON transaction_entries FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Ledger entries are immutable';
END$$

CREATE TRIGGER trg_entries_bd BEFORE DELETE ON transaction_entries FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Ledger entries cannot be deleted';
END$$

/* =====================================================================
   4. STORED PROCEDURES
   Error pattern (blueprint): EXIT HANDLER -> ROLLBACK -> log failure in
   audit_logs (committed separately) -> RESIGNAL (re-raise to caller).
   ===================================================================== */

-- Writes a failure record AFTER the rollback so it is not undone
CREATE PROCEDURE sp_log_failure(
    IN p_operation VARCHAR(20), IN p_account VARCHAR(16), IN p_target VARCHAR(16),
    IN p_amount DECIMAL(15,2), IN p_reference VARCHAR(40),
    IN p_sqlstate CHAR(5), IN p_message TEXT)
BEGIN
    INSERT INTO audit_logs(actor, action, entity_type, entity_id, details)
    VALUES (COALESCE(@app_user, USER()), 'OPERATION_FAILED', 'ACCOUNT',
            (SELECT account_id FROM accounts WHERE account_number = p_account),
            JSON_OBJECT('operation', p_operation, 'account', p_account, 'target', p_target,
                        'amount', p_amount, 'reference', p_reference,
                        'sqlstate', p_sqlstate, 'error', LEFT(p_message, 400)));
    COMMIT;
END$$

-- ---------- MODULE 1: customers & accounts ----------
CREATE PROCEDURE sp_register_customer(
    IN p_full_name VARCHAR(100), IN p_email VARCHAR(120), IN p_phone CHAR(10),
    IN p_address VARCHAR(255), OUT p_customer_id INT)
BEGIN
    INSERT INTO customers(full_name, email, phone, address)
    VALUES (p_full_name, p_email, p_phone, p_address);
    SET p_customer_id = LAST_INSERT_ID();
END$$

CREATE PROCEDURE sp_create_account(
    IN p_customer_id INT, IN p_account_type VARCHAR(10), OUT p_account_number VARCHAR(16))
BEGIN
    DECLARE v_id INT;
    DECLARE v_state CHAR(5) DEFAULT '00000';
    DECLARE v_msg TEXT;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
        ROLLBACK;
        CALL sp_log_failure('CREATE_ACCOUNT', NULL, NULL, NULL, NULL, v_state, v_msg);
        RESIGNAL;
    END;

    START TRANSACTION;
    IF NOT EXISTS (SELECT 1 FROM customers WHERE customer_id = p_customer_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Customer not found';
    END IF;

    -- placeholder number, replaced with a number derived from the new id
    INSERT INTO accounts(customer_id, account_number, account_type)
    VALUES (p_customer_id, LEFT(REPLACE(UUID(), '-', ''), 16), p_account_type);
    SET v_id = LAST_INSERT_ID();
    SET p_account_number = CONCAT('ACC', LPAD(v_id, 10, '0'));
    UPDATE accounts SET account_number = p_account_number WHERE account_id = v_id;
    COMMIT;
END$$

CREATE PROCEDURE sp_set_account_status(IN p_account_number VARCHAR(16), IN p_new_status VARCHAR(10))
BEGIN
    DECLARE v_id INT;
    DECLARE v_state CHAR(5) DEFAULT '00000';
    DECLARE v_msg TEXT;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
        ROLLBACK;
        CALL sp_log_failure(CONCAT('SET_', p_new_status), p_account_number, NULL, NULL, NULL, v_state, v_msg);
        RESIGNAL;
    END;

    START TRANSACTION;
    SELECT account_id INTO v_id FROM accounts WHERE account_number = p_account_number FOR UPDATE;
    IF v_id IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Account not found';
    END IF;
    UPDATE accounts SET status = p_new_status WHERE account_id = v_id;   -- triggers enforce rules
    COMMIT;
END$$

-- ---------- MODULE 2a: deposit ----------
CREATE PROCEDURE sp_deposit(
    IN  p_account_number VARCHAR(16),
    IN  p_amount         DECIMAL(15,2),
    IN  p_reference      VARCHAR(40),          -- NULL = auto-generate
    OUT p_transaction_id BIGINT)
BEGIN
    DECLARE v_id INT;
    DECLARE v_balance DECIMAL(15,2);
    DECLARE v_acc_status VARCHAR(10);
    DECLARE v_ref VARCHAR(40);
    DECLARE v_state CHAR(5) DEFAULT '00000';
    DECLARE v_msg TEXT;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
        ROLLBACK;
        SET p_transaction_id = NULL;
        CALL sp_log_failure('DEPOSIT', p_account_number, NULL, p_amount, v_ref, v_state, v_msg);
        RESIGNAL;
    END;

    SET v_ref = COALESCE(p_reference, fn_new_reference('DEP'));
    IF p_amount IS NULL OR p_amount <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Deposit amount must be positive';
    END IF;

    START TRANSACTION;

    IF EXISTS (SELECT 1 FROM transactions WHERE reference = v_ref) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Duplicate transaction reference';
    END IF;

    SELECT account_id, balance, status INTO v_id, v_balance, v_acc_status
      FROM accounts WHERE account_number = p_account_number FOR UPDATE;      -- row lock

    IF v_id IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Account not found';
    ELSEIF v_acc_status <> 'ACTIVE' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Account is not active';
    END IF;

    INSERT INTO transactions(transaction_type, amount, status, reference)
    VALUES ('DEPOSIT', p_amount, 'PENDING', v_ref);
    SET p_transaction_id = LAST_INSERT_ID();

    UPDATE accounts SET balance = balance + p_amount WHERE account_id = v_id;

    INSERT INTO transaction_entries(transaction_id, account_id, entry_type, amount, balance_after)
    VALUES (p_transaction_id, v_id, 'CREDIT', p_amount, v_balance + p_amount);

    UPDATE transactions SET status = 'COMPLETED' WHERE transaction_id = p_transaction_id;
    COMMIT;
END$$

-- ---------- MODULE 2b: withdraw ----------
CREATE PROCEDURE sp_withdraw(
    IN  p_account_number VARCHAR(16),
    IN  p_amount         DECIMAL(15,2),
    IN  p_reference      VARCHAR(40),
    OUT p_transaction_id BIGINT)
BEGIN
    DECLARE v_id INT;
    DECLARE v_balance DECIMAL(15,2);
    DECLARE v_acc_status VARCHAR(10);
    DECLARE v_ref VARCHAR(40);
    DECLARE v_state CHAR(5) DEFAULT '00000';
    DECLARE v_msg TEXT;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
        ROLLBACK;
        SET p_transaction_id = NULL;
        CALL sp_log_failure('WITHDRAWAL', p_account_number, NULL, p_amount, v_ref, v_state, v_msg);
        RESIGNAL;
    END;

    SET v_ref = COALESCE(p_reference, fn_new_reference('WDR'));
    IF p_amount IS NULL OR p_amount <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Withdrawal amount must be positive';
    END IF;

    START TRANSACTION;

    IF EXISTS (SELECT 1 FROM transactions WHERE reference = v_ref) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Duplicate transaction reference';
    END IF;

    SELECT account_id, balance, status INTO v_id, v_balance, v_acc_status
      FROM accounts WHERE account_number = p_account_number FOR UPDATE;

    IF v_id IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Account not found';
    ELSEIF v_acc_status <> 'ACTIVE' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Account is not active';
    ELSEIF v_balance < p_amount THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Insufficient funds';
    END IF;

    INSERT INTO transactions(transaction_type, amount, status, reference)
    VALUES ('WITHDRAWAL', p_amount, 'PENDING', v_ref);
    SET p_transaction_id = LAST_INSERT_ID();

    UPDATE accounts SET balance = balance - p_amount WHERE account_id = v_id;

    INSERT INTO transaction_entries(transaction_id, account_id, entry_type, amount, balance_after)
    VALUES (p_transaction_id, v_id, 'DEBIT', p_amount, v_balance - p_amount);

    UPDATE transactions SET status = 'COMPLETED' WHERE transaction_id = p_transaction_id;
    COMMIT;
END$$

-- ---------- MODULE 3: transfer (ACID, deadlock-safe) ----------
CREATE PROCEDURE sp_transfer(
    IN  p_from_account   VARCHAR(16),
    IN  p_to_account     VARCHAR(16),
    IN  p_amount         DECIMAL(15,2),
    IN  p_reference      VARCHAR(40),
    OUT p_transaction_id BIGINT)
BEGIN
    DECLARE v_from_id INT;        DECLARE v_to_id INT;
    DECLARE v_from_bal DECIMAL(15,2);  DECLARE v_to_bal DECIMAL(15,2);
    DECLARE v_from_status VARCHAR(10); DECLARE v_to_status VARCHAR(10);
    DECLARE v_ref VARCHAR(40);
    DECLARE v_state CHAR(5) DEFAULT '00000';
    DECLARE v_msg TEXT;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
        ROLLBACK;                                   -- both balances restored
        SET p_transaction_id = NULL;
        CALL sp_log_failure('TRANSFER', p_from_account, p_to_account, p_amount, v_ref, v_state, v_msg);
        RESIGNAL;
    END;

    SET v_ref = COALESCE(p_reference, fn_new_reference('TRF'));
    IF p_amount IS NULL OR p_amount <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Transfer amount must be positive';
    END IF;
    IF p_from_account = p_to_account THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Cannot transfer to the same account';
    END IF;

    START TRANSACTION;

    IF EXISTS (SELECT 1 FROM transactions WHERE reference = v_ref) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Duplicate transaction reference';
    END IF;

    -- 1. Lock both rows in a consistent order (lowest account_id first)
    SELECT account_id INTO v_from_id FROM accounts WHERE account_number = p_from_account;
    SELECT account_id INTO v_to_id   FROM accounts WHERE account_number = p_to_account;
    IF v_from_id IS NULL OR v_to_id IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Source or destination account not found';
    END IF;

    IF v_from_id < v_to_id THEN
        SELECT balance, status INTO v_from_bal, v_from_status FROM accounts WHERE account_id = v_from_id FOR UPDATE;
        SELECT balance, status INTO v_to_bal,   v_to_status   FROM accounts WHERE account_id = v_to_id   FOR UPDATE;
    ELSE
        SELECT balance, status INTO v_to_bal,   v_to_status   FROM accounts WHERE account_id = v_to_id   FOR UPDATE;
        SELECT balance, status INTO v_from_bal, v_from_status FROM accounts WHERE account_id = v_from_id FOR UPDATE;
    END IF;

    -- 2. Accounts active?   3. Sufficient funds?
    IF v_from_status <> 'ACTIVE' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Source account is not active';
    ELSEIF v_to_status <> 'ACTIVE' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Destination account is not active';
    ELSEIF v_from_bal < p_amount THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Insufficient funds';
    END IF;

    -- 4. Transaction header (+ transfer link)
    INSERT INTO transactions(transaction_type, amount, status, reference)
    VALUES ('TRANSFER', p_amount, 'PENDING', v_ref);
    SET p_transaction_id = LAST_INSERT_ID();
    INSERT INTO transfers(transaction_id, from_account_id, to_account_id)
    VALUES (p_transaction_id, v_from_id, v_to_id);

    -- 5. Debit source
    UPDATE accounts SET balance = balance - p_amount WHERE account_id = v_from_id;

    -- TEST HOOK: set @simulate_failure = 1 to prove the rollback after the debit
    IF @simulate_failure = 1 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Simulated failure after debit (test hook)';
    END IF;

    -- 6. Credit destination
    UPDATE accounts SET balance = balance + p_amount WHERE account_id = v_to_id;

    -- 7. Matching ledger entries
    INSERT INTO transaction_entries(transaction_id, account_id, entry_type, amount, balance_after)
    VALUES (p_transaction_id, v_from_id, 'DEBIT',  p_amount, v_from_bal - p_amount),
           (p_transaction_id, v_to_id,   'CREDIT', p_amount, v_to_bal + p_amount);

    -- 8. Verify entries balance
    IF fn_entries_balanced(p_transaction_id) = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Ledger entries do not balance';
    END IF;

    UPDATE transactions SET status = 'COMPLETED' WHERE transaction_id = p_transaction_id;
    COMMIT;
END$$

-- ---------- MODULE 4: history ----------
CREATE PROCEDURE sp_get_statement(IN p_account_number VARCHAR(16), IN p_from DATE, IN p_to DATE)
BEGIN
    SELECT * FROM v_account_statement
     WHERE account_number = p_account_number
       AND created_at >= p_from AND created_at < p_to + INTERVAL 1 DAY
     ORDER BY entry_id;
END$$

-- Any filter may be NULL (= ignore)
CREATE PROCEDURE sp_search_transactions(
    IN p_account_number VARCHAR(16), IN p_from DATE, IN p_to DATE,
    IN p_type VARCHAR(12), IN p_status VARCHAR(10), IN p_reference VARCHAR(40))
BEGIN
    SELECT t.transaction_id, t.reference, t.transaction_type, t.status, t.amount, t.created_at,
           a.account_number, e.entry_type
    FROM transactions t
    JOIN transaction_entries e ON e.transaction_id = t.transaction_id
    JOIN accounts a            ON a.account_id = e.account_id
    WHERE (p_account_number IS NULL OR a.account_number = p_account_number)
      AND (p_from      IS NULL OR t.created_at >= p_from)
      AND (p_to        IS NULL OR t.created_at <  p_to + INTERVAL 1 DAY)
      AND (p_type      IS NULL OR t.transaction_type = p_type)
      AND (p_status    IS NULL OR t.status = p_status)
      AND (p_reference IS NULL OR t.reference = p_reference)
    ORDER BY t.transaction_id, e.entry_id;
END$$

DELIMITER ;

/* =====================================================================
   5. VIEWS
   ===================================================================== */

CREATE VIEW v_account_statement AS
SELECT a.account_number, e.entry_id, t.created_at, t.reference, t.transaction_type,
       e.entry_type, e.amount, e.balance_after, t.status
FROM transaction_entries e
JOIN transactions t ON t.transaction_id = e.transaction_id
JOIN accounts a     ON a.account_id = e.account_id;

CREATE VIEW v_account_balances AS
SELECT a.account_number, c.full_name, a.account_type, a.balance, a.status
FROM accounts a JOIN customers c ON c.customer_id = a.customer_id;

CREATE VIEW v_transaction_summary AS
SELECT DATE(created_at) AS txn_date, transaction_type,
       COUNT(*) AS txn_count, SUM(amount) AS total_amount
FROM transactions
WHERE status = 'COMPLETED'
GROUP BY DATE(created_at), transaction_type;

-- Integrity checks: both views must return ZERO rows
CREATE VIEW v_balance_mismatch AS
SELECT a.account_number, a.balance AS stored_balance,
       COALESCE(SUM(CASE e.entry_type WHEN 'CREDIT' THEN e.amount ELSE -e.amount END), 0) AS ledger_balance
FROM accounts a
LEFT JOIN transaction_entries e ON e.account_id = a.account_id
GROUP BY a.account_id, a.account_number, a.balance
HAVING stored_balance <> ledger_balance;

CREATE VIEW v_unbalanced_transfers AS
SELECT t.transaction_id, t.reference
FROM transactions t
WHERE t.transaction_type = 'TRANSFER' AND t.status = 'COMPLETED'
  AND fn_entries_balanced(t.transaction_id) = 0;

/* =====================================================================
   6. SAMPLE DATA  (Phase 3, fictional)
   ===================================================================== */

CALL sp_register_customer('Aarav Sharma', 'aarav.sharma@example.com', '9876500001', 'Indiranagar, Bengaluru', @c1);
CALL sp_register_customer('Priya Nair',   'priya.nair@example.com',   '9876500002', 'Koramangala, Bengaluru', @c2);
CALL sp_register_customer('Rohan Mehta',  'rohan.mehta@example.com',  '9876500003', 'Saket, New Delhi',       @c3);
CALL sp_register_customer('Sneha Iyer',   'sneha.iyer@example.com',   '9876500004', 'Whitefield, Bengaluru',  @c4);

CALL sp_create_account(@c1, 'SAVINGS', @acc_a);    -- "Account A"
CALL sp_create_account(@c2, 'SAVINGS', @acc_b);    -- "Account B"
CALL sp_create_account(@c3, 'CURRENT', @acc_c);
CALL sp_create_account(@c1, 'SALARY',  @acc_d);

-- Blueprint example: A = 10,000 and B = 2,000
CALL sp_deposit(@acc_a, 10000.00, 'SEED-A-001', @t);
CALL sp_deposit(@acc_b,  2000.00, 'SEED-B-001', @t);
CALL sp_deposit(@acc_c, 80000.00, 'SEED-C-001', @t);
CALL sp_deposit(@acc_d,  5000.00, 'SEED-D-001', @t);

INSERT INTO users(username, password_hash, role, customer_id) VALUES
  ('admin',   SHA2('Admin@123', 256),  'ADMIN',    NULL),
  ('teller1', SHA2('Teller@123', 256), 'TELLER',   NULL),
  ('aarav',   SHA2('Aarav@123', 256),  'CUSTOMER', @c1),
  ('priya',   SHA2('Priya@123', 256),  'CUSTOMER', @c2);

/* =====================================================================
   7. AUTOMATED TEST SUITE  (Phase 9 -- section 8 of the blueprint)
   Procedures raise errors on purpose, so each case is executed through
   a harness that catches the error and records PASS/FAIL.
   ===================================================================== */

CREATE TEMPORARY TABLE test_results (
    id        INT AUTO_INCREMENT PRIMARY KEY,
    test_name VARCHAR(120),
    expected  VARCHAR(120),
    actual    VARCHAR(255),
    result    VARCHAR(4)
);

DELIMITER $$

-- Runs a CALL/DML string; p_expect_error = 1 means the statement MUST fail
CREATE PROCEDURE sp_run_case(IN p_name VARCHAR(120), IN p_sql TEXT, IN p_expect_error TINYINT)
BEGIN
    DECLARE v_failed TINYINT DEFAULT 0;
    DECLARE v_msg TEXT DEFAULT 'no error';
    DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 v_msg = MESSAGE_TEXT;
        SET v_failed = 1;
    END;

    SET @case_sql = p_sql;
    PREPARE case_stmt FROM @case_sql;
    EXECUTE case_stmt;
    DEALLOCATE PREPARE case_stmt;

    INSERT INTO test_results(test_name, expected, actual, result)
    VALUES (p_name, IF(p_expect_error, 'rejected', 'success'), LEFT(v_msg, 255),
            IF(v_failed = p_expect_error, 'PASS', 'FAIL'));
END$$

CREATE PROCEDURE sp_assert_balance(IN p_name VARCHAR(120), IN p_account VARCHAR(16), IN p_expected DECIMAL(15,2))
BEGIN
    INSERT INTO test_results(test_name, expected, actual, result)
    SELECT p_name, CONCAT('balance = ', p_expected), CONCAT('balance = ', balance),
           IF(balance = p_expected, 'PASS', 'FAIL')
    FROM accounts WHERE account_number = p_account;
END$$

CREATE PROCEDURE sp_assert_count(IN p_name VARCHAR(120), IN p_actual BIGINT, IN p_expected BIGINT)
BEGIN
    INSERT INTO test_results(test_name, expected, actual, result)
    VALUES (p_name, CONCAT('count = ', p_expected), CONCAT('count = ', p_actual),
            IF(p_actual = p_expected, 'PASS', 'FAIL'));
END$$

DELIMITER ;

-- T1  Deposit 1,000 -> balance +1,000
CALL sp_run_case('T1 deposit 1000 succeeds',
     CONCAT('CALL sp_deposit(''', @acc_a, ''', 1000, ''T-DEP-1'', @tid)'), 0);
CALL sp_assert_balance('T1 balance A = 11000', @acc_a, 11000.00);

-- T2  Withdraw 500 with sufficient funds
CALL sp_run_case('T2 withdraw 500 succeeds',
     CONCAT('CALL sp_withdraw(''', @acc_a, ''', 500, ''T-WDR-1'', @tid)'), 0);
CALL sp_assert_balance('T2 balance A = 10500', @acc_a, 10500.00);

-- T3  Withdraw more than available -> rejected, balance unchanged
CALL sp_run_case('T3 overdraw rejected',
     CONCAT('CALL sp_withdraw(''', @acc_a, ''', 999999, ''T-WDR-2'', @tid)'), 1);
CALL sp_assert_balance('T3 balance A unchanged', @acc_a, 10500.00);

-- T4  Transfer 3,000 -> source down, destination up by the same amount
CALL sp_run_case('T4 transfer 3000 succeeds',
     CONCAT('CALL sp_transfer(''', @acc_a, ''', ''', @acc_b, ''', 3000, ''T-TRF-1'', @tid)'), 0);
CALL sp_assert_balance('T4 balance A = 7500', @acc_a, 7500.00);
CALL sp_assert_balance('T4 balance B = 5000', @acc_b, 5000.00);

-- T5  Transfer fails halfway (after debit, before credit) -> full rollback
SET @simulate_failure = 1;
CALL sp_run_case('T5 mid-transfer failure rejected',
     CONCAT('CALL sp_transfer(''', @acc_a, ''', ''', @acc_b, ''', 1000, ''T-TRF-2'', @tid)'), 1);
SET @simulate_failure = 0;
CALL sp_assert_balance('T5 balance A unchanged', @acc_a, 7500.00);
CALL sp_assert_balance('T5 balance B unchanged', @acc_b, 5000.00);
CALL sp_assert_count('T5 no leftover header for failed transfer',
     (SELECT COUNT(*) FROM transactions WHERE reference = 'T-TRF-2'), 0);

-- T6  Negative deposit rejected
CALL sp_run_case('T6 negative deposit rejected',
     CONCAT('CALL sp_deposit(''', @acc_a, ''', -100, ''T-DEP-NEG'', @tid)'), 1);

-- T7  Reused reference rejected (idempotency)
CALL sp_run_case('T7 reuse of reference T-DEP-1 rejected',
     CONCAT('CALL sp_deposit(''', @acc_a, ''', 1000, ''T-DEP-1'', @tid)'), 1);
CALL sp_assert_balance('T7 balance A unchanged', @acc_a, 7500.00);

-- T8  Extra business rules
CALL sp_run_case('T8a self-transfer rejected',
     CONCAT('CALL sp_transfer(''', @acc_a, ''', ''', @acc_a, ''', 10, ''T-SELF'', @tid)'), 1);
CALL sp_run_case('T8b freeze account', CONCAT('CALL sp_set_account_status(''', @acc_d, ''', ''FROZEN'')'), 0);
CALL sp_run_case('T8c withdraw from frozen rejected',
     CONCAT('CALL sp_withdraw(''', @acc_d, ''', 10, ''T-FRZ'', @tid)'), 1);
CALL sp_run_case('T8d close account with balance rejected',
     CONCAT('CALL sp_set_account_status(''', @acc_d, ''', ''CLOSED'')'), 1);
CALL sp_run_case('T8e unfreeze account', CONCAT('CALL sp_set_account_status(''', @acc_d, ''', ''ACTIVE'')'), 0);

-- T9  Constraints and immutable ledger
CALL sp_run_case('T9a direct negative balance blocked (CHECK)',
     CONCAT('UPDATE accounts SET balance = -1 WHERE account_number = ''', @acc_a, ''''), 1);
CALL sp_run_case('T9b ledger entry update blocked',
     'UPDATE transaction_entries SET amount = 1 WHERE entry_id = 1', 1);
CALL sp_run_case('T9c ledger entry delete blocked',
     'DELETE FROM transaction_entries WHERE entry_id = 1', 1);
CALL sp_run_case('T9d completed transaction update blocked',
     'UPDATE transactions SET amount = 1 WHERE transaction_id = 1', 1);

-- T10 Integrity: ledger matches balances, all transfers balanced, failures were audited
CALL sp_assert_count('T10a balance mismatches', (SELECT COUNT(*) FROM v_balance_mismatch), 0);
CALL sp_assert_count('T10b unbalanced transfers', (SELECT COUNT(*) FROM v_unbalanced_transfers), 0);
CALL sp_assert_count('T10c failures logged in audit_logs',
     (SELECT COUNT(*) FROM audit_logs WHERE action = 'OPERATION_FAILED') > 0, 1);

-- T11 History search returns the right record
CALL sp_assert_count('T11 search by reference finds 1 transfer (2 entries)',
     (SELECT COUNT(*) FROM transaction_entries e JOIN transactions t USING (transaction_id)
       WHERE t.reference = 'T-TRF-1'), 2);

SELECT * FROM test_results;
SELECT result, COUNT(*) AS tests FROM test_results GROUP BY result;

/* =====================================================================
   8. HISTORY SEARCH DEMOS  (Module 4)
   ===================================================================== */
CALL sp_get_statement(@acc_a, CURDATE() - INTERVAL 30 DAY, CURDATE());
CALL sp_search_transactions(NULL, NULL, NULL, 'TRANSFER', 'COMPLETED', NULL);
CALL sp_search_transactions(NULL, NULL, NULL, NULL, NULL, 'T-DEP-1');

/* =====================================================================
   9. REPORTS & ANALYTICS  (Phase 8 / Module 5)
   ===================================================================== */

-- 9.1 Total deposits and withdrawals
SELECT transaction_type, COUNT(*) AS txn_count, SUM(amount) AS total_amount
FROM transactions WHERE status = 'COMPLETED' AND transaction_type IN ('DEPOSIT','WITHDRAWAL')
GROUP BY transaction_type;

-- 9.2 Daily transaction counts / monthly transaction values
SELECT * FROM v_transaction_summary ORDER BY txn_date, transaction_type;
SELECT DATE_FORMAT(created_at, '%Y-%m') AS month, COUNT(*) AS txn_count, SUM(amount) AS total_value
FROM transactions WHERE status = 'COMPLETED'
GROUP BY DATE_FORMAT(created_at, '%Y-%m') ORDER BY month;

-- 9.3 Top accounts by balance (window function: RANK)
SELECT RANK() OVER (ORDER BY a.balance DESC) AS balance_rank,
       a.account_number, c.full_name, a.balance
FROM accounts a JOIN customers c ON c.customer_id = a.customer_id;

-- 9.4 Subquery: accounts with balance above the average
SELECT account_number, balance
FROM accounts
WHERE balance > (SELECT AVG(balance) FROM accounts WHERE status = 'ACTIVE');

-- 9.5 Running total per account (window function: SUM OVER)
SELECT account_number, created_at, transaction_type, entry_type, amount,
       SUM(CASE entry_type WHEN 'CREDIT' THEN amount ELSE -amount END)
           OVER (PARTITION BY account_number ORDER BY entry_id) AS running_balance
FROM v_account_statement;

-- 9.6 Join: customer portfolio
SELECT c.full_name, COUNT(a.account_id) AS accounts, COALESCE(SUM(a.balance), 0) AS total_balance
FROM customers c LEFT JOIN accounts a ON a.customer_id = c.customer_id
GROUP BY c.customer_id, c.full_name ORDER BY total_balance DESC;

-- 9.7 Audit trail
SELECT log_id, actor, action, entity_type, entity_id, details, created_at
FROM audit_logs ORDER BY log_id DESC LIMIT 20;

-- 9.8 Integrity checks (must be empty)
SELECT * FROM v_balance_mismatch;
SELECT * FROM v_unbalanced_transfers;

/* =====================================================================
   10. CONCURRENCY TEST  (Isolation) -- run in TWO mysql sessions
   ---------------------------------------------------------------------
   Session 1:  START TRANSACTION;
               SELECT balance FROM accounts WHERE account_number = '<acc>' FOR UPDATE;
   Session 2:  CALL sp_withdraw('<acc>', 100, NULL, @t);   -- blocks until session 1 ends
   Session 1:  COMMIT;                                      -- session 2 now proceeds
   Opposite transfers (A->B and B->A simultaneously) cannot deadlock
   because sp_transfer always locks the lower account_id first.
   ===================================================================== */

/* =====================================================================
   11. OPTIONAL: ROLE-BASED ACCESS
   ===================================================================== */
-- CREATE ROLE IF NOT EXISTS 'teller_role', 'auditor_role';
-- GRANT EXECUTE ON bank_db.* TO 'teller_role';
-- GRANT SELECT ON bank_db.v_account_balances TO 'teller_role';
-- GRANT SELECT ON bank_db.audit_logs TO 'auditor_role';

-- PRACTICE
/* =====================================================================
   BANKING SYSTEM - 50 PRACTICE QUESTIONS WITH MYSQL ANSWERS
   ---------------------------------------------------------------------
   Prerequisites (run once, in this order):
       1. banking_system.sql          (schema + procedures + sample data)
       2. banking_practice_setup.sql  (extra customers + back-dated history)

   HOW TO USE: every question is a comment (-- Qn) followed by its answer.
   No DELIMITER is needed, so in Workbench you can HIGHLIGHT one query
   (from its SELECT to its semicolon) and press Ctrl+Enter.

   ACCOUNT NUMBERS USED BELOW
     ACC0000000001 Aarav  SAVINGS   ACC0000000005 Kavya  SAVINGS
     ACC0000000002 Priya  SAVINGS   ACC0000000006 Arjun  CURRENT
     ACC0000000003 Rohan  CURRENT   ACC0000000007 Meera  SAVINGS
     ACC0000000004 Aarav  SALARY    ACC0000000008 Vikram SALARY

   Sections
     A  Basic queries ........ Q1  - Q8
     B  Joins ................ Q9  - Q16
     C  Aggregates ........... Q17 - Q24
     D  Subqueries ........... Q25 - Q30
     E  Window functions/CTE . Q31 - Q38
     F  Views, functions, procedures ... Q39 - Q45
     G  Transactions, audit, integrity . Q46 - Q50
   ===================================================================== */

USE bank_db;

/* =====================================================================
   A. BASIC QUERIES
   ===================================================================== */

-- Q1. Display all customers.
SELECT * FROM customers;

-- Q2. Find customers who live in Bengaluru.
SELECT customer_id, full_name, address
FROM customers
WHERE address LIKE '%Bengaluru%';

-- Q3. List active SAVINGS accounts with a balance above 10,000, richest first.
SELECT account_number, account_type, balance
FROM accounts
WHERE account_type = 'SAVINGS' AND status = 'ACTIVE' AND balance > 10000
ORDER BY balance DESC;

-- Q4. Find customers whose name starts with a vowel.
SELECT customer_id, full_name
FROM customerss
WHERE full_name REGEXP '^[AEIOU]';

-- Q5. Show the top 3 accounts by balance.
SELECT account_number, balance
FROM accounts
ORDER BY balance DESC
LIMIT 3;

-- Q6. List all accounts that are SAVINGS or SALARY type (use IN).
SELECT account_number, account_type, balance
FROM accounts
WHERE account_type IN ('SAVINGS', 'SALARY');

-- Q7. Show all transactions made in August 2026, oldest first.
SELECT reference, transaction_type, amount, created_at
FROM transactions
WHERE created_at BETWEEN '2026-08-01 00:00:00' AND '2026-08-31 23:59:59'
ORDER BY created_at;

-- Q8. Which transaction types exist in the system? (DISTINCT)
SELECT DISTINCT transaction_type
FROM transactions;

/* =====================================================================
   B. JOINS
   ===================================================================== */

-- Q9. Show every account with its owner's name (INNER JOIN).
SELECT a.account_number, c.full_name, a.account_type, a.balance
FROM accounts a
JOIN customers c ON c.customer_id = a.customer_id
ORDER BY c.full_name;

-- Q10. Find customers who do not have any account (LEFT JOIN ... IS NULL).
SELECT c.customer_id, c.full_name
FROM customers c
LEFT JOIN accounts a ON a.customer_id = c.customer_id
WHERE a.account_id IS NULL;

-- Q11. Print the full statement of Kavya's account (3-table join).
SELECT t.created_at, t.reference, t.transaction_type, e.entry_type, e.amount, e.balance_after
FROM transaction_entries e
JOIN transactions t ON t.transaction_id = e.transaction_id
JOIN accounts a     ON a.account_id = e.account_id
WHERE a.account_number = 'ACC0000000005'
ORDER BY t.created_at, e.entry_id;

-- Q12. List all transfers with sender and receiver names (joining accounts and customers twice).
SELECT t.reference, t.amount, t.created_at,
       c_from.full_name AS sender,   a_from.account_number AS from_account,
       c_to.full_name   AS receiver, a_to.account_number   AS to_account
FROM transfers tr
JOIN transactions t     ON t.transaction_id = tr.transaction_id
JOIN accounts a_from    ON a_from.account_id = tr.from_account_id
JOIN customers c_from   ON c_from.customer_id = a_from.customer_id
JOIN accounts a_to      ON a_to.account_id = tr.to_account_id
JOIN customers c_to     ON c_to.customer_id = a_to.customer_id
ORDER BY t.created_at;

-- Q13. Which customers own more than one account?
SELECT c.full_name, COUNT(*) AS account_count
FROM customers c
JOIN accounts a ON a.customer_id = c.customer_id
GROUP BY c.customer_id, c.full_name
HAVING COUNT(*) > 1;

-- Q14. List all application users with their linked customer (if any).
SELECT u.username, u.role, c.full_name AS linked_customer
FROM users u
LEFT JOIN customers c ON c.customer_id = u.customer_id;

-- Q15. Find accounts that have never had any transaction entry.
SELECT a.account_number, a.balance
FROM accounts a
LEFT JOIN transaction_entries e ON e.account_id = a.account_id
WHERE e.entry_id IS NULL;

-- Q16. Self join: list pairs of accounts that belong to the same customer.
SELECT a1.account_number AS account_1, a2.account_number AS account_2, a1.customer_id
FROM accounts a1
JOIN accounts a2 ON a1.customer_id = a2.customer_id AND a1.account_id < a2.account_id;

/* =====================================================================
   C. AGGREGATES, GROUP BY, HAVING
   ===================================================================== */

-- Q17. What is the total amount of money held by the bank?
SELECT SUM(balance) AS total_bank_balance
FROM accounts;

-- Q18. Count, total and average balance for each account type.
SELECT account_type, COUNT(*) AS accounts, SUM(balance) AS total_balance, ROUND(AVG(balance), 2) AS avg_balance
FROM accounts
GROUP BY account_type;

-- Q19. Total deposits and total withdrawals in one row (conditional aggregation).
SELECT SUM(CASE WHEN transaction_type = 'DEPOSIT'    THEN amount ELSE 0 END) AS total_deposits,
       SUM(CASE WHEN transaction_type = 'WITHDRAWAL' THEN amount ELSE 0 END) AS total_withdrawals
FROM transactions
WHERE status = 'COMPLETED';

-- Q20. How many transactions exist for each type and status?
SELECT transaction_type, status, COUNT(*) AS txn_count
FROM transactions
GROUP BY transaction_type, status;

-- Q21. Average transaction amount per transaction type.
SELECT transaction_type, ROUND(AVG(amount), 2) AS avg_amount
FROM transactions
GROUP BY transaction_type;

-- Q22. Which customers hold more than 50,000 in total across all accounts? (HAVING)
SELECT c.full_name, SUM(a.balance) AS total_balance
FROM customers c
JOIN accounts a ON a.customer_id = c.customer_id
GROUP BY c.customer_id, c.full_name
HAVING SUM(a.balance) > 50000
ORDER BY total_balance DESC;

-- Q23. Monthly deposit totals.
SELECT DATE_FORMAT(created_at, '%Y-%m') AS month, COUNT(*) AS deposits, SUM(amount) AS total_deposited
FROM transactions
WHERE transaction_type = 'DEPOSIT' AND status = 'COMPLETED'
GROUP BY DATE_FORMAT(created_at, '%Y-%m')
ORDER BY month;

-- Q24. Show the single largest and the single smallest transaction.
(SELECT 'LARGEST' AS kind, reference, transaction_type, amount FROM transactions ORDER BY amount DESC LIMIT 1)
UNION ALL
(SELECT 'SMALLEST', reference, transaction_type, amount FROM transactions ORDER BY amount ASC LIMIT 1);

/* =====================================================================
   D. SUBQUERIES
   ===================================================================== */

-- Q25. Find accounts whose balance is above the average balance (scalar subquery).
SELECT account_number, balance
FROM accounts
WHERE balance > (SELECT AVG(balance) FROM accounts);

-- Q26. Find customers who have sent at least one transfer (IN subquery).
SELECT customer_id, full_name
FROM customers
WHERE customer_id IN (SELECT a.customer_id
                      FROM transfers tr
                      JOIN accounts a ON a.account_id = tr.from_account_id);

-- Q27. Find accounts that have never made a withdrawal (NOT EXISTS).
SELECT a.account_number, a.balance
FROM accounts a
WHERE NOT EXISTS (SELECT 1
                  FROM transaction_entries e
                  JOIN transactions t ON t.transaction_id = e.transaction_id
                  WHERE e.account_id = a.account_id AND t.transaction_type = 'WITHDRAWAL');

-- Q28. Which account has the highest balance?
SELECT account_number, balance
FROM accounts
WHERE balance = (SELECT MAX(balance) FROM accounts);

-- Q29. Customers whose total balance is above the average customer total (derived tables).
SELECT customer_id, total_balance
FROM (SELECT customer_id, SUM(balance) AS total_balance FROM accounts GROUP BY customer_id) AS per_customer
WHERE total_balance > (SELECT AVG(total_balance)
                       FROM (SELECT SUM(balance) AS total_balance FROM accounts GROUP BY customer_id) AS x);

-- Q30. For each account show its largest single ledger entry (correlated subquery).
SELECT a.account_number,
       (SELECT MAX(e.amount) FROM transaction_entries e WHERE e.account_id = a.account_id) AS largest_entry
FROM accounts a;

/* =====================================================================
   E. WINDOW FUNCTIONS & CTEs
   ===================================================================== */

-- Q31. Rank all accounts by balance (RANK leaves gaps after ties).
SELECT RANK() OVER (ORDER BY balance DESC) AS balance_rank, account_number, balance
FROM accounts;

-- Q32. Rank accounts by balance within each account type (DENSE_RANK + PARTITION BY).
SELECT account_type, account_number, balance,
       DENSE_RANK() OVER (PARTITION BY account_type ORDER BY balance DESC) AS rank_in_type
FROM accounts;

-- Q33. Running balance for every account, calculated from the ledger.
SELECT a.account_number, t.created_at, t.transaction_type, e.entry_type, e.amount,
       SUM(CASE e.entry_type WHEN 'CREDIT' THEN e.amount ELSE -e.amount END)
           OVER (PARTITION BY a.account_id ORDER BY t.created_at, e.entry_id) AS running_balance
FROM transaction_entries e
JOIN transactions t ON t.transaction_id = e.transaction_id
JOIN accounts a     ON a.account_id = e.account_id
ORDER BY a.account_number, t.created_at, e.entry_id;

-- Q34. Show each entry together with the previous entry's amount (LAG).
SELECT a.account_number, t.created_at, e.entry_type, e.amount,
       LAG(e.amount) OVER (PARTITION BY a.account_id ORDER BY t.created_at, e.entry_id) AS previous_amount
FROM transaction_entries e
JOIN transactions t ON t.transaction_id = e.transaction_id
JOIN accounts a     ON a.account_id = e.account_id
ORDER BY a.account_number, t.created_at, e.entry_id;

-- Q35. Monthly net cash flow (deposits - withdrawals) with a cumulative total (CTE + window).
WITH monthly AS (
    SELECT DATE_FORMAT(created_at, '%Y-%m') AS ym,
           SUM(CASE transaction_type WHEN 'DEPOSIT' THEN amount
                                     WHEN 'WITHDRAWAL' THEN -amount ELSE 0 END) AS net_flow
    FROM transactions
    WHERE status = 'COMPLETED'
    GROUP BY DATE_FORMAT(created_at, '%Y-%m')
)
SELECT ym, net_flow, SUM(net_flow) OVER (ORDER BY ym) AS cumulative_net_flow
FROM monthly;

-- Q36. Top 2 largest ledger entries per account (ROW_NUMBER in a CTE).
WITH ranked AS (
    SELECT a.account_number, t.reference, t.transaction_type, e.amount,
           ROW_NUMBER() OVER (PARTITION BY a.account_id ORDER BY e.amount DESC) AS rn
    FROM transaction_entries e
    JOIN transactions t ON t.transaction_id = e.transaction_id
    JOIN accounts a     ON a.account_id = e.account_id
)
SELECT account_number, reference, transaction_type, amount
FROM ranked
WHERE rn <= 2
ORDER BY account_number, rn;

-- Q37. What percentage of the bank's total money does each account hold?
SELECT account_number, balance,
       ROUND(100 * balance / SUM(balance) OVER (), 2) AS pct_of_bank
FROM accounts
ORDER BY pct_of_bank DESC;

-- Q38. Completed transaction value for each of the last 6 months, including months with no activity (recursive CTE).
WITH RECURSIVE months AS (
    SELECT DATE_SUB(CURDATE(), INTERVAL DAYOFMONTH(CURDATE()) - 1 DAY) AS month_start, 1 AS n
    UNION ALL
    SELECT month_start - INTERVAL 1 MONTH, n + 1 FROM months WHERE n < 6
)
SELECT DATE_FORMAT(m.month_start, '%Y-%m') AS month,
       COUNT(t.transaction_id)             AS txn_count,
       COALESCE(SUM(t.amount), 0)          AS total_value
FROM months m
LEFT JOIN transactions t
       ON t.created_at >= m.month_start
      AND t.created_at <  m.month_start + INTERVAL 1 MONTH
      AND t.status = 'COMPLETED'
GROUP BY m.month_start
ORDER BY m.month_start;

/* =====================================================================
   F. VIEWS, FUNCTIONS & STORED PROCEDURES
   ===================================================================== */

-- Q39. Use the view to list active accounts with owner names, richest first.
SELECT * FROM v_account_balances
WHERE status = 'ACTIVE'
ORDER BY balance DESC;

-- Q40. Use the statement view to show Arjun's account activity.
SELECT account_number, created_at, reference, transaction_type, entry_type, amount, balance_after
FROM v_account_statement
WHERE account_number = 'ACC0000000006'
ORDER BY created_at, entry_id;

-- Q41. Check with the function that every transfer has balanced debit/credit entries (1 = balanced).
SELECT transaction_id, reference, fn_entries_balanced(transaction_id) AS is_balanced
FROM transactions
WHERE transaction_type = 'TRANSFER';

-- Q42. Deposit 1,000 into Kavya's account using the procedure (auto-generated reference), then show the result.
CALL sp_deposit('ACC0000000005', 1000, NULL, @new_txn);
SELECT @new_txn AS transaction_id, balance FROM accounts WHERE account_number = 'ACC0000000005';

-- Q43. Transfer 2,500 from Arjun to Kavya and show both ledger entries that were created.
CALL sp_transfer('ACC0000000006', 'ACC0000000005', 2500, NULL, @new_transfer);
SELECT e.transaction_id, a.account_number, e.entry_type, e.amount, e.balance_after
FROM transaction_entries e
JOIN accounts a ON a.account_id = e.account_id
WHERE e.transaction_id = @new_transfer;

-- Q44. Search history: all completed TRANSFERS involving Kavya's account.
CALL sp_search_transactions('ACC0000000005', NULL, NULL, 'TRANSFER', 'COMPLETED', NULL);

-- Q45. Create (or replace) a view that shows each customer's total balance and number of accounts.
CREATE OR REPLACE VIEW v_customer_totals AS
SELECT c.customer_id, c.full_name,
       COUNT(a.account_id)         AS accounts,
       COALESCE(SUM(a.balance), 0) AS total_balance
FROM customers c
LEFT JOIN accounts a ON a.customer_id = c.customer_id
GROUP BY c.customer_id, c.full_name;

SELECT * FROM v_customer_totals ORDER BY total_balance DESC;

/* =====================================================================
   G. TRANSACTIONS, TRIGGERS, AUDIT & INTEGRITY
   ===================================================================== */

-- Q46. Demonstrate ROLLBACK: reduce a balance inside a transaction, then undo it.
--      (Select all lines from START TRANSACTION to the last SELECT and run together.)
START TRANSACTION;
UPDATE accounts SET balance = balance - 100 WHERE account_number = 'ACC0000000005';
SELECT 'inside transaction' AS step, balance FROM accounts WHERE account_number = 'ACC0000000005';
ROLLBACK;
SELECT 'after rollback' AS step, balance FROM accounts WHERE account_number = 'ACC0000000005';

-- Q47. Demonstrate SAVEPOINT: undo only part of a transaction.
START TRANSACTION;
UPDATE accounts SET balance = balance + 500 WHERE account_number = 'ACC0000000007';
SAVEPOINT after_first_update;
UPDATE accounts SET balance = balance + 900 WHERE account_number = 'ACC0000000007';
ROLLBACK TO SAVEPOINT after_first_update;      -- undoes only the +900
SELECT 'at savepoint' AS step, balance FROM accounts WHERE account_number = 'ACC0000000007';
ROLLBACK;                                      -- undoes everything
SELECT 'after full rollback' AS step, balance FROM accounts WHERE account_number = 'ACC0000000007';

-- Q48. Read the audit trail of one account: when did its balance change and to what? (JSON functions)
SELECT created_at, action,
       JSON_UNQUOTE(JSON_EXTRACT(details, '$.old_balance')) AS old_balance,
       JSON_UNQUOTE(JSON_EXTRACT(details, '$.new_balance')) AS new_balance
FROM audit_logs
WHERE entity_type = 'ACCOUNT'
  AND action = 'BALANCE_CHANGED'
  AND entity_id = (SELECT account_id FROM accounts WHERE account_number = 'ACC0000000001')
ORDER BY log_id;

-- Q49. Failed-operation report: how often did each error occur, per operation?
SELECT JSON_UNQUOTE(JSON_EXTRACT(details, '$.operation')) AS operation,
       JSON_UNQUOTE(JSON_EXTRACT(details, '$.error'))     AS error_message,
       COUNT(*) AS occurrences
FROM audit_logs
WHERE action = 'OPERATION_FAILED'
GROUP BY operation, error_message
ORDER BY occurrences DESC;

-- Q50. Integrity audit: compare every stored balance with the balance rebuilt from the ledger.
--      Zero rows = the bank's books are perfectly consistent.
SELECT a.account_number,
       a.balance AS stored_balance,
       COALESCE(SUM(CASE e.entry_type WHEN 'CREDIT' THEN e.amount ELSE -e.amount END), 0) AS ledger_balance
FROM accounts a
LEFT JOIN transaction_entries e ON e.account_id = a.account_id
GROUP BY a.account_id, a.account_number, a.balance
HAVING stored_balance <> ledger_balance;



/* =====================================================================
   BULK TEST DATA  (100+ rows in every table)
   ---------------------------------------------------------------------
   Run AFTER banking_system.sql  (and after banking_practice_setup.sql
   if you use that file).  Safe to re-run: does nothing if already loaded.

   Adds (approximate):
     customers ........ 100        accounts ............ 120
     transactions ..... ~290       transaction_entries . ~350
     transfers ........ ~60        users ............... 100
     audit_logs ....... ~700 (created by triggers + one row per transaction)

   Every money movement is posted as a proper ledger entry with
   balance_after, so v_balance_mismatch and v_unbalanced_transfers stay empty.
   History is back-dated (15 Apr 2026 onward) so monthly reports have data.

   HOW TO RUN IN MYSQL WORKBENCH
     File > Open SQL Script > click in the editor so NOTHING is highlighted
     > Ctrl+Shift+Enter  (Execute All).   Takes a few seconds.
   ===================================================================== */

USE bank_db;

DROP PROCEDURE IF EXISTS sp_bulk_entry;
DROP PROCEDURE IF EXISTS sp_bulk_transfer;
DROP PROCEDURE IF EXISTS sp_bulk_load;

DELIMITER $$

-- Back-dated DEPOSIT / WITHDRAWAL with ledger entry, balance update and audit row
CREATE PROCEDURE sp_bulk_entry(
    IN p_acc_id INT, IN p_type VARCHAR(12), IN p_amount DECIMAL(15,2), IN p_ts DATETIME)
BEGIN
    DECLARE v_bal DECIMAL(15,2);
    DECLARE v_new DECIMAL(15,2);
    DECLARE v_tid BIGINT;
    DECLARE v_ref VARCHAR(40);

    SELECT balance INTO v_bal FROM accounts WHERE account_id = p_acc_id;
    SET v_new = IF(p_type = 'DEPOSIT', v_bal + p_amount, v_bal - p_amount);
    SET v_ref = fn_new_reference('BULK');

    INSERT INTO transactions(transaction_type, amount, status, reference, created_at)
    VALUES (p_type, p_amount, 'COMPLETED', v_ref, p_ts);
    SET v_tid = LAST_INSERT_ID();

    UPDATE accounts SET balance = v_new WHERE account_id = p_acc_id;

    INSERT INTO transaction_entries(transaction_id, account_id, entry_type, amount, balance_after)
    VALUES (v_tid, p_acc_id, IF(p_type = 'DEPOSIT', 'CREDIT', 'DEBIT'), p_amount, v_new);

    INSERT INTO audit_logs(actor, action, entity_type, entity_id, details, created_at)
    VALUES (USER(), 'TXN_COMPLETED', 'TRANSACTION', v_tid,
            JSON_OBJECT('type', p_type, 'amount', p_amount, 'reference', v_ref), p_ts);
END$$

-- Back-dated TRANSFER (header + transfers row + debit/credit entries + audit row)
CREATE PROCEDURE sp_bulk_transfer(
    IN p_from INT, IN p_to INT, IN p_amount DECIMAL(15,2), IN p_ts DATETIME)
BEGIN
    DECLARE v_fb DECIMAL(15,2);
    DECLARE v_tb DECIMAL(15,2);
    DECLARE v_tid BIGINT;
    DECLARE v_ref VARCHAR(40);

    SELECT balance INTO v_fb FROM accounts WHERE account_id = p_from;
    SELECT balance INTO v_tb FROM accounts WHERE account_id = p_to;
    SET v_ref = fn_new_reference('BULK');

    INSERT INTO transactions(transaction_type, amount, status, reference, created_at)
    VALUES ('TRANSFER', p_amount, 'COMPLETED', v_ref, p_ts);
    SET v_tid = LAST_INSERT_ID();

    INSERT INTO transfers(transaction_id, from_account_id, to_account_id)
    VALUES (v_tid, p_from, p_to);

    UPDATE accounts SET balance = v_fb - p_amount WHERE account_id = p_from;
    UPDATE accounts SET balance = v_tb + p_amount WHERE account_id = p_to;

    INSERT INTO transaction_entries(transaction_id, account_id, entry_type, amount, balance_after)
    VALUES (v_tid, p_from, 'DEBIT',  p_amount, v_fb - p_amount),
           (v_tid, p_to,   'CREDIT', p_amount, v_tb + p_amount);

    INSERT INTO audit_logs(actor, action, entity_type, entity_id, details, created_at)
    VALUES (USER(), 'TXN_COMPLETED', 'TRANSACTION', v_tid,
            JSON_OBJECT('type', 'TRANSFER', 'amount', p_amount, 'reference', v_ref), p_ts);
END$$

CREATE PROCEDURE sp_bulk_load()
bulk: BEGIN
    DECLARE i INT DEFAULT 1;
    DECLARE k INT DEFAULT 1;
    DECLARE m INT;
    DECLARE v_n INT DEFAULT 117;            -- accounts that receive transactions
    DECLARE v_base_c INT;
    DECLARE v_base_a INT;
    DECLARE v_fn VARCHAR(20);
    DECLARE v_ln VARCHAR(20);
    DECLARE v_acc VARCHAR(16);
    DECLARE v_ts DATETIME;
    DECLARE v_a INT;
    DECLARE v_b INT;
    DECLARE v_amt DECIMAL(15,2);
    DECLARE v_bal DECIMAL(15,2);

    IF EXISTS (SELECT 1 FROM customers WHERE email = 'aarav.sharma001@example.com') THEN
        SELECT 'Bulk data already loaded - nothing to do' AS info;
        LEAVE bulk;
    END IF;

    SELECT COALESCE(MAX(customer_id), 0) INTO v_base_c FROM customers;
    SELECT COALESCE(MAX(account_id), 0)  INTO v_base_a FROM accounts;

    /* ---------- 100 customers ---------- */
    START TRANSACTION;
    WHILE i <= 100 DO
        SET v_fn = ELT(MOD(i - 1, 20) + 1,
            'Aarav','Vivaan','Aditya','Arjun','Ishaan','Rohan','Kabir','Rahul','Karan','Siddharth',
            'Ananya','Diya','Isha','Kavya','Meera','Neha','Pooja','Riya','Sanya','Tanvi');
        SET v_ln = ELT(MOD((i - 1) * 7 + FLOOR((i - 1) / 20), 20) + 1,
            'Sharma','Verma','Gupta','Nair','Iyer','Reddy','Patel','Mehta','Singh','Kumar',
            'Joshi','Desai','Rao','Das','Bose','Menon','Shah','Kapoor','Malhotra','Chopra');

        INSERT INTO customers(full_name, email, phone, address, created_at)
        VALUES (CONCAT(v_fn, ' ', v_ln),
                LOWER(CONCAT(v_fn, '.', v_ln, LPAD(i, 3, '0'), '@example.com')),
                CONCAT('91', LPAD(i, 8, '0')),
                CONCAT(10 + MOD(i * 3, 90), ' ',
                       ELT(MOD(i, 10) + 1,
                           'Indiranagar, Bengaluru','Koramangala, Bengaluru','Andheri, Mumbai',
                           'Bandra, Mumbai','Saket, New Delhi','Dwarka, New Delhi','T Nagar, Chennai',
                           'Salt Lake, Kolkata','Banjara Hills, Hyderabad','Koregaon Park, Pune')),
                '2026-01-05 10:00:00' + INTERVAL i DAY);
        SET i = i + 1;
    END WHILE;
    COMMIT;

    /* ---------- 120 accounts: one per customer + 20 second accounts ---------- */
    SET i = 1;
    WHILE i <= 100 DO
        CALL sp_create_account(v_base_c + i, ELT(MOD(i, 3) + 1, 'SAVINGS', 'CURRENT', 'SALARY'), v_acc);
        SET i = i + 1;
    END WHILE;
    SET i = 5;
    WHILE i <= 100 DO
        CALL sp_create_account(v_base_c + i, ELT(MOD(i + 1, 3) + 1, 'SAVINGS', 'CURRENT', 'SALARY'), v_acc);
        SET i = i + 5;
    END WHILE;

    UPDATE accounts a JOIN customers c ON c.customer_id = a.customer_id
       SET a.created_at = c.created_at + INTERVAL 1 HOUR
     WHERE a.account_id > v_base_a;

    /* ---------- ~290 transactions (chronological) ----------
       k = 1..117 : opening deposit for each active account
       k > 117    : 50% withdrawals, 33% transfers, 17% deposits        */
    START TRANSACTION;
    WHILE k <= 300 DO
        SET v_ts = '2026-04-15 09:00:00' + INTERVAL (k * 6) HOUR + INTERVAL MOD(k * 7, 50) MINUTE;

        IF k <= v_n THEN
            CALL sp_bulk_entry(v_base_a + k, 'DEPOSIT', 5000 + MOD(k * 7919, 90) * 1000, v_ts);
        ELSE
            SET m = MOD(k, 6);
            IF m IN (0, 1, 2) THEN                                  -- withdrawal
                SET v_a   = v_base_a + 1 + MOD(k * 37, v_n);
                SET v_amt = (1 + MOD(k * 13, 16)) * 500;
                SELECT balance INTO v_bal FROM accounts WHERE account_id = v_a;
                IF v_bal >= v_amt THEN
                    CALL sp_bulk_entry(v_a, 'WITHDRAWAL', v_amt, v_ts);
                END IF;
            ELSEIF m IN (3, 4) THEN                                 -- transfer
                SET v_a = v_base_a + 1 + MOD(k * 41, v_n);
                SET v_b = v_base_a + 1 + MOD(v_a - v_base_a + k, v_n);
                IF v_b = v_a THEN
                    SET v_b = v_base_a + 1 + MOD(v_a - v_base_a, v_n);
                END IF;
                SET v_amt = (1 + MOD(k * 17, 20)) * 250;
                SELECT balance INTO v_bal FROM accounts WHERE account_id = v_a;
                IF v_bal >= v_amt THEN
                    CALL sp_bulk_transfer(v_a, v_b, v_amt, v_ts);
                END IF;
            ELSE                                                    -- extra deposit
                SET v_a   = v_base_a + 1 + MOD(k * 53, v_n);
                SET v_amt = (1 + MOD(k * 11, 30)) * 1000;
                CALL sp_bulk_entry(v_a, 'DEPOSIT', v_amt, v_ts);
            END IF;
        END IF;
        SET k = k + 1;
    END WHILE;
    COMMIT;

    /* ---------- account status variety ---------- */
    UPDATE accounts SET status = 'FROZEN'
     WHERE account_id IN (v_base_a + 10, v_base_a + 25, v_base_a + 40, v_base_a + 55, v_base_a + 70);
    UPDATE accounts SET status = 'CLOSED'          -- the 3 dormant accounts have a zero balance
     WHERE account_id IN (v_base_a + 118, v_base_a + 119, v_base_a + 120);

    /* ---------- 100 application users ---------- */
    INSERT INTO users(username, password_hash, role, customer_id)
    SELECT CONCAT('cust', LPAD(c.customer_id - v_base_c, 3, '0')),
           SHA2(CONCAT('Pass@', LPAD(c.customer_id - v_base_c, 3, '0')), 256),
           IF(MOD(c.customer_id - v_base_c, 25) = 0, 'TELLER', 'CUSTOMER'),
           c.customer_id
    FROM customers c
    WHERE c.customer_id > v_base_c;

    SELECT 'Bulk data loaded' AS info;
END$$

DELIMITER ;

CALL sp_bulk_load();

DROP PROCEDURE sp_bulk_entry;
DROP PROCEDURE sp_bulk_transfer;
DROP PROCEDURE sp_bulk_load;

/* =====================================================================
   VERIFY: row counts per table  +  integrity checks (must be 0)
   ===================================================================== */
SELECT 'customers' AS table_name, COUNT(*) AS row_count FROM customers
UNION ALL SELECT 'accounts',            COUNT(*) FROM accounts
UNION ALL SELECT 'transactions',        COUNT(*) FROM transactions
UNION ALL SELECT 'transaction_entries', COUNT(*) FROM transaction_entries
UNION ALL SELECT 'transfers',           COUNT(*) FROM transfers
UNION ALL SELECT 'audit_logs',          COUNT(*) FROM audit_logs
UNION ALL SELECT 'users',               COUNT(*) FROM users;

SELECT COUNT(*) AS balance_mismatches   FROM v_balance_mismatch;
SELECT COUNT(*) AS unbalanced_transfers FROM v_unbalanced_transfers;
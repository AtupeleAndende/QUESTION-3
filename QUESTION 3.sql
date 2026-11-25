-- ============================================================
-- Q3: LIBRARY RETURNS AND OVERDUE FINES
-- ============================================================

-- ---------- (a) DATABASE: TABLES ----------
CREATE TABLE books (
    book_id SERIAL PRIMARY KEY,
    title   VARCHAR(150) NOT NULL
);

SELECT * FROM books;

CREATE TABLE loans (
    loan_id       SERIAL PRIMARY KEY,
    book_id       INT NOT NULL REFERENCES books(book_id),
    borrower_name VARCHAR(100) NOT NULL,
    borrowed_on   DATE NOT NULL,
    due_on        DATE NOT NULL,
    returned_on   DATE NULL,
    fine_amount   NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
    CONSTRAINT chk_due_after_borrow CHECK (due_on >= borrowed_on)
);

SELECT * FROM loans;

CREATE TABLE loan_audit (
    audit_id        SERIAL PRIMARY KEY,
    loan_id         INT NOT NULL REFERENCES loans(loan_id),
    old_returned_on DATE NULL,
    new_returned_on DATE NULL,
    changed_at      TIMESTAMP NOT NULL DEFAULT now()
);

SELECT * FROM loan_audit;

CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INT NOT NULL,
    total_fine    NUMERIC(12,2) NOT NULL
);

SELECT * FROM overdue_summary;

-- ---------- (b) FUNCTION ----------
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INT, p_as_of DATE)
RETURNS NUMERIC LANGUAGE plpgsql AS $$
DECLARE v_due DATE; v_ret DATE; v_end DATE;
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'As-of date is required';
    END IF;
    SELECT due_on, returned_on INTO v_due, v_ret FROM loans WHERE loan_id = p_loan_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan id: %', p_loan_id;
    END IF;
    v_end := LEAST(p_as_of, COALESCE(v_ret, p_as_of));   -- earlier of as-of and return date
    RETURN 2 * GREATEST(v_end - v_due, 0);                -- K2/day, minimum 0
END $$;

-- ---------- (c) PROCEDURE ----------
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INT, p_returned_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_borrowed DATE; v_ret DATE; v_fine NUMERIC;
BEGIN
    IF p_returned_on IS NULL THEN
        RAISE EXCEPTION 'Return date is required';
    END IF;
    SELECT borrowed_on, returned_on INTO v_borrowed, v_ret
    FROM loans WHERE loan_id = p_loan_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan id: %', p_loan_id;
    END IF;
    IF v_ret IS NOT NULL THEN
        RAISE EXCEPTION 'Loan % was already returned on %', p_loan_id, v_ret;
    END IF;
    IF p_returned_on < v_borrowed THEN
        RAISE EXCEPTION 'Return date % is before borrow date %', p_returned_on, v_borrowed;
    END IF;

    v_fine := fn_loan_fine(p_loan_id, p_returned_on);

    UPDATE loans SET returned_on = p_returned_on, fine_amount = v_fine
    WHERE loan_id = p_loan_id;                    -- date and final fine together
END $$;

-- ---------- (d) TRIGGER ----------
CREATE OR REPLACE FUNCTION trg_fn_loan_audit() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO loan_audit(loan_id, old_returned_on, new_returned_on)
    VALUES (OLD.loan_id, OLD.returned_on, NEW.returned_on);
    RETURN NEW;
END $$;

CREATE TRIGGER trg_loan_audit
AFTER UPDATE ON loans
FOR EACH ROW
WHEN (OLD.returned_on IS DISTINCT FROM NEW.returned_on)
EXECUTE FUNCTION trg_fn_loan_audit();

-- ---------- (a) SEED DATA ----------
INSERT INTO books(title) VALUES ('Database Systems'), ('Operating Systems'), ('Computer Networks');

INSERT INTO loans(book_id, borrower_name, borrowed_on, due_on) VALUES
 (1, 'Mwansa',  CURRENT_DATE-30, CURRENT_DATE-16),  -- open, overdue
 (2, 'Chanda',  CURRENT_DATE-5,  CURRENT_DATE+9),   -- open, on time
 (3, 'Temwani', CURRENT_DATE-40, CURRENT_DATE-26),  -- to be returned late
 (1, 'Natasha', CURRENT_DATE-20, CURRENT_DATE-6),   -- to be returned on the due date
 (2, 'Bwalya',  CURRENT_DATE-12, CURRENT_DATE-2),   -- open, overdue
 (3, 'Mutale',  CURRENT_DATE-3,  CURRENT_DATE+11);  -- open, on time

CALL pr_return_loan(3, CURRENT_DATE-20);  -- 6 days late -> K12
CALL pr_return_loan(4, CURRENT_DATE-6);   -- on due date -> K0

-- ---------- (e) VIEW ----------
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT b.title, l.borrower_name, l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_today
FROM loans l
JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL AND l.due_on < CURRENT_DATE;

SELECT * FROM v_overdue_loans;

-- ---------- (f) INDEX ----------
-- Partial index: only unreturned loans are indexed, so it stays small
-- and matches the "unreturned loans of a book" search exactly.
CREATE INDEX idx_loans_book_unreturned ON loans(book_id) WHERE returned_on IS NULL;

-- SET enable_seqscan = off;
EXPLAIN
SELECT * FROM loans WHERE book_id = 1 AND returned_on IS NULL;

-- ---------- (g) SCHEDULED JOB ----------
-- "Overdue" here = unreturned as of the date AND due_on < p_as_of.
-- If your lecturer wants every unreturned loan counted, drop the due_on condition.
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO overdue_summary(snapshot_date, overdue_count, total_fine)
    SELECT p_as_of, COUNT(*), COALESCE(SUM(fn_loan_fine(l.loan_id, p_as_of)),0)
    FROM loans l
    WHERE l.borrowed_on <= p_as_of
      AND (l.returned_on IS NULL OR l.returned_on > p_as_of)   -- still unreturned that day
      AND l.due_on < p_as_of
    ON CONFLICT (snapshot_date) DO UPDATE
    SET overdue_count = EXCLUDED.overdue_count, total_fine = EXCLUDED.total_fine;
END $$;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh_overdue', '10 0 * * *',
       $$CALL pr_refresh_overdue(CURRENT_DATE)$$);
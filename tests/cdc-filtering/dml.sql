-- CDC changes to public schema (should be applied)
INSERT INTO public.users (username, email) VALUES
    ('dave', 'dave@example.com'),
    ('eve', 'eve@example.com');

UPDATE public.users SET email = 'alice.new@example.com' WHERE username = 'alice';

DELETE FROM public.orders WHERE id = 1;

INSERT INTO public.orders (user_id, amount) VALUES
    (3, 500.00);

-- CDC changes to cron schema (should be FILTERED OUT)
INSERT INTO cron.job_run_details (job_id, status) VALUES
    (3, 'running'),
    (4, 'pending');

UPDATE cron.job_run_details SET status = 'completed' WHERE job_id = 2;

DELETE FROM cron.scheduled_jobs WHERE id = 1;

INSERT INTO cron.scheduled_jobs (job_name, schedule) VALUES
    ('backup', '0 2 * * *');

-- CDC changes to excluded_schema (should be FILTERED OUT)
INSERT INTO excluded_schema.test_table (data) VALUES
    ('this should not appear on target');

UPDATE excluded_schema.test_table SET data = 'updated but should not appear' WHERE id = 1;

-- Cross a WAL boundary inside one mixed transaction. The filtered statement
-- must not remove the BEGIN needed by the included statement after the switch.
BEGIN;
UPDATE excluded_schema.test_table SET data = 'filtered before WAL switch' WHERE id = 1;
SELECT pg_switch_wal();
UPDATE public.users SET email = 'charlie.boundary@example.com' WHERE username = 'charlie';
COMMIT;

-- More public changes (should be applied)
UPDATE public.users SET username = 'robert' WHERE username = 'bob';

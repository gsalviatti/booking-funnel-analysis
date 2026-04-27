-- ============================================================
-- PROJECT: Booking Completion & Cart Conversion Funnel
-- Author:  Gabriela Salviatti
-- Stack:   PostgreSQL / T-SQL compatible
-- Description:
--   Analyzes the customer booking funnel to identify drop-off
--   points, correlates cart conversion with appointment lead
--   time, and segments cohorts by booking behavior.
-- ============================================================


-- ────────────────────────────────────────────────────────────
-- STEP 1: Base funnel events per session
-- ────────────────────────────────────────────────────────────
WITH funnel_base AS (
    SELECT
        session_id,
        customer_id,
        store_id,
        MIN(CASE WHEN event_type = 'page_view'        THEN event_ts END) AS ts_page_view,
        MIN(CASE WHEN event_type = 'service_selected' THEN event_ts END) AS ts_service_selected,
        MIN(CASE WHEN event_type = 'slot_selected'    THEN event_ts END) AS ts_slot_selected,
        MIN(CASE WHEN event_type = 'cart_add'         THEN event_ts END) AS ts_cart_add,
        MIN(CASE WHEN event_type = 'checkout_start'   THEN event_ts END) AS ts_checkout_start,
        MIN(CASE WHEN event_type = 'booking_complete' THEN event_ts END) AS ts_booking_complete
    FROM booking_events
    WHERE event_ts >= DATEADD(day, -90, GETDATE())   -- rolling 90-day window
    GROUP BY session_id, customer_id, store_id
),

-- ────────────────────────────────────────────────────────────
-- STEP 2: Enrich with lead time (hours between booking & appt)
-- ────────────────────────────────────────────────────────────
funnel_enriched AS (
    SELECT
        f.*,
        a.appointment_ts,
        DATEDIFF(hour, f.ts_booking_complete, a.appointment_ts) AS lead_time_hours,

        -- Funnel stage flags
        CASE WHEN f.ts_service_selected IS NOT NULL THEN 1 ELSE 0 END AS reached_service,
        CASE WHEN f.ts_slot_selected    IS NOT NULL THEN 1 ELSE 0 END AS reached_slot,
        CASE WHEN f.ts_cart_add         IS NOT NULL THEN 1 ELSE 0 END AS reached_cart,
        CASE WHEN f.ts_checkout_start   IS NOT NULL THEN 1 ELSE 0 END AS reached_checkout,
        CASE WHEN f.ts_booking_complete IS NOT NULL THEN 1 ELSE 0 END AS completed_booking
    FROM funnel_base f
    LEFT JOIN appointments a
        ON f.session_id = a.session_id
),

-- ────────────────────────────────────────────────────────────
-- STEP 3: Lead-time buckets for segmentation
-- ────────────────────────────────────────────────────────────
funnel_bucketed AS (
    SELECT
        *,
        CASE
            WHEN lead_time_hours < 24             THEN 'Same Day'
            WHEN lead_time_hours BETWEEN 24 AND 71 THEN '1–3 Days'
            WHEN lead_time_hours BETWEEN 72 AND 167 THEN '3–7 Days'
            ELSE '7+ Days'
        END AS lead_time_bucket
    FROM funnel_enriched
),

-- ────────────────────────────────────────────────────────────
-- STEP 4: Cohort conversion rates by lead-time bucket
-- ────────────────────────────────────────────────────────────
cohort_conversion AS (
    SELECT
        lead_time_bucket,
        COUNT(*)                                                AS total_sessions,
        SUM(reached_cart)                                       AS sessions_reached_cart,
        SUM(completed_booking)                                  AS sessions_completed,
        ROUND(100.0 * SUM(reached_cart)      / COUNT(*), 2)    AS cart_add_rate_pct,
        ROUND(100.0 * SUM(completed_booking) / COUNT(*), 2)    AS completion_rate_pct,
        ROUND(100.0 * SUM(completed_booking)
              / NULLIF(SUM(reached_cart), 0), 2)               AS cart_to_completion_pct
    FROM funnel_bucketed
    GROUP BY lead_time_bucket
),

-- ────────────────────────────────────────────────────────────
-- STEP 5: Drop-off waterfall (overall)
-- ────────────────────────────────────────────────────────────
drop_off_waterfall AS (
    SELECT
        'Page View'        AS funnel_stage, 1 AS stage_order, COUNT(*)             AS sessions FROM funnel_bucketed
    UNION ALL SELECT 'Service Selected', 2, SUM(reached_service)                               FROM funnel_bucketed
    UNION ALL SELECT 'Slot Selected',    3, SUM(reached_slot)                                  FROM funnel_bucketed
    UNION ALL SELECT 'Cart Add',         4, SUM(reached_cart)                                  FROM funnel_bucketed
    UNION ALL SELECT 'Checkout Start',   5, SUM(reached_checkout)                              FROM funnel_bucketed
    UNION ALL SELECT 'Booking Complete', 6, SUM(completed_booking)                             FROM funnel_bucketed
),

-- ────────────────────────────────────────────────────────────
-- STEP 6: Stage-over-stage drop-off rate using window function
-- ────────────────────────────────────────────────────────────
drop_off_rates AS (
    SELECT
        funnel_stage,
        stage_order,
        sessions,
        LAG(sessions) OVER (ORDER BY stage_order) AS prev_stage_sessions,
        ROUND(
            100.0 * (LAG(sessions) OVER (ORDER BY stage_order) - sessions)
            / NULLIF(LAG(sessions) OVER (ORDER BY stage_order), 0),
        2) AS drop_off_pct
    FROM drop_off_waterfall
),

-- ────────────────────────────────────────────────────────────
-- STEP 7: Store-level performance ranking
-- ────────────────────────────────────────────────────────────
store_performance AS (
    SELECT
        store_id,
        COUNT(*)                                                AS total_sessions,
        SUM(completed_booking)                                  AS bookings_completed,
        ROUND(100.0 * SUM(completed_booking) / COUNT(*), 2)    AS completion_rate_pct,
        AVG(CAST(lead_time_hours AS FLOAT))                     AS avg_lead_time_hours,
        RANK() OVER (ORDER BY ROUND(100.0 * SUM(completed_booking) / COUNT(*), 2) DESC)
                                                                AS completion_rank
    FROM funnel_bucketed
    GROUP BY store_id
)

-- ────────────────────────────────────────────────────────────
-- FINAL OUTPUT 1: Conversion by lead-time bucket
-- ────────────────────────────────────────────────────────────
SELECT
    lead_time_bucket,
    total_sessions,
    sessions_reached_cart,
    sessions_completed,
    cart_add_rate_pct        AS [Cart Add Rate %],
    completion_rate_pct      AS [Booking Completion Rate %],
    cart_to_completion_pct   AS [Cart → Completion %]
FROM cohort_conversion
ORDER BY
    CASE lead_time_bucket
        WHEN 'Same Day'  THEN 1
        WHEN '1–3 Days'  THEN 2
        WHEN '3–7 Days'  THEN 3
        ELSE 4
    END;


-- ────────────────────────────────────────────────────────────
-- FINAL OUTPUT 2: Drop-off waterfall
-- ────────────────────────────────────────────────────────────
SELECT
    funnel_stage,
    sessions,
    drop_off_pct AS [Drop-off from Previous Stage %]
FROM drop_off_rates
ORDER BY stage_order;


-- ────────────────────────────────────────────────────────────
-- FINAL OUTPUT 3: Top / bottom stores by completion rate
-- ────────────────────────────────────────────────────────────
SELECT
    store_id,
    total_sessions,
    bookings_completed,
    completion_rate_pct,
    avg_lead_time_hours,
    completion_rank
FROM store_performance
ORDER BY completion_rank;

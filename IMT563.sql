/*
IMT 563: Advanced Relational Database Management Systems
Deliverable: OLAP and Window Function Queries for Movie and Theater Data Warehouse
Group Members: Jihan Yang, Raymond Xu
Database Platform: PostgreSQL

Assumed dimensional warehouse tables:
  dim_time(time_key, full_date, day, month, month_name, quarter, year, decade)
  dim_movie(movie_key, movie_title, runtime_minutes, language, content_rating,
            synopsis_text, content_type, source_award, year, primary_creator, theater_name)
  dim_market(market_key, market_name)
  dim_theater(theater_key, theater_source_id, theater_name, address,
              current_location_name, location_city)
  dim_company(company_key, company_name, sector)
  fact_movie_performance(movie_key, time_key, market_key, box_office_rev, tickets_sold)
  fact_theater_operations(theater_key, time_key, revenue_est, attendance, capacity_pct)
  fact_industry_metrics(company_key, time_key, annual_revenue, annual_profit)

Purpose of this script:
  These queries use temporary result objects, CTEs, SET operators, aggregate functions,
  and SQL window functions to extract policy and managerial insights about movie demand,
  theater operations, market performance, and industry-level financial trends.
*/

/* ============================================================================
   QUERY 1
   Purpose: Rank movies by annual market revenue and identify the top performers
            in each market-year.
   Techniques: CTEs, multiple joins, aggregate functions, ranking window function,
               HAVING, string/date formatting, LIMIT.
   Interpretation / policy implication:
            Markets where only a few movies dominate annual revenue may require
            more diversified programming strategies. Policy makers and theater
            managers can use this result to identify whether local demand depends
            heavily on blockbuster titles or is spread across a broader movie mix.
============================================================================ */
WITH movie_market_year AS (
    SELECT
        dt.year AS release_year,
        dm.market_name,
        INITCAP(TRIM(dmv.movie_title)) AS movie_title,
        COALESCE(NULLIF(TRIM(dmv.content_rating), ''), 'Unrated') AS content_rating,
        SUM(fmp.box_office_rev) AS total_box_office_revenue,
        SUM(fmp.tickets_sold) AS total_tickets_sold,
        ROUND(
            SUM(fmp.box_office_rev)::numeric / NULLIF(SUM(fmp.tickets_sold), 0),
            2
        ) AS estimated_avg_ticket_price
    FROM fact_movie_performance AS fmp
        INNER JOIN dim_movie AS dmv
            ON fmp.movie_key = dmv.movie_key
        INNER JOIN dim_market AS dm
            ON fmp.market_key = dm.market_key
        INNER JOIN dim_time AS dt
            ON fmp.time_key = dt.time_key
    GROUP BY
        dt.year,
        dm.market_name,
        INITCAP(TRIM(dmv.movie_title)),
        COALESCE(NULLIF(TRIM(dmv.content_rating), ''), 'Unrated')
    HAVING
        SUM(fmp.box_office_rev) > 0
        AND SUM(fmp.tickets_sold) > 0
), ranked_movies AS (
    SELECT
        release_year,
        market_name,
        movie_title,
        content_rating,
        total_box_office_revenue,
        total_tickets_sold,
        estimated_avg_ticket_price,
        DENSE_RANK() OVER (
            PARTITION BY release_year, market_name
            ORDER BY total_box_office_revenue DESC
        ) AS revenue_rank_in_market_year
    FROM movie_market_year
)
SELECT
    release_year,
    market_name,
    movie_title,
    content_rating,
    TO_CHAR(total_box_office_revenue, 'FM$999,999,999,990') AS total_box_office_revenue,
    TO_CHAR(total_tickets_sold, 'FM999,999,999,990') AS total_tickets_sold,
    TO_CHAR(estimated_avg_ticket_price, 'FM$999,990.00') AS estimated_avg_ticket_price,
    revenue_rank_in_market_year
FROM ranked_movies
WHERE revenue_rank_in_market_year <= 5
ORDER BY
    release_year DESC,
    market_name,
    revenue_rank_in_market_year,
    movie_title
LIMIT 100;


/* ============================================================================
   QUERY 2
   Purpose: Measure year-over-year market growth in revenue and ticket sales.
   Techniques: CTEs, joins, aggregate functions, LAG value window function,
               growth-rate calculation, filtering, date formatting.
   Interpretation / policy implication:
            Positive revenue growth with weak ticket growth may indicate price-driven
            growth rather than expanded audience participation. Markets with negative
            revenue and ticket trends may need targeted investment, marketing, or
            programming changes.
============================================================================ */
WITH annual_market_metrics AS (
    SELECT
        dm.market_name,
        dt.year,
        SUM(fmp.box_office_rev) AS annual_revenue,
        SUM(fmp.tickets_sold) AS annual_tickets
    FROM fact_movie_performance AS fmp
        INNER JOIN dim_market AS dm
            ON fmp.market_key = dm.market_key
        INNER JOIN dim_time AS dt
            ON fmp.time_key = dt.time_key
    GROUP BY
        dm.market_name,
        dt.year
), market_trends AS (
    SELECT
        market_name,
        year,
        annual_revenue,
        annual_tickets,
        LAG(annual_revenue) OVER (
            PARTITION BY market_name
            ORDER BY year
        ) AS prior_year_revenue,
        LAG(annual_tickets) OVER (
            PARTITION BY market_name
            ORDER BY year
        ) AS prior_year_tickets
    FROM annual_market_metrics
)
SELECT
    market_name,
    year,
    TO_CHAR(annual_revenue, 'FM$999,999,999,990') AS annual_revenue,
    TO_CHAR(prior_year_revenue, 'FM$999,999,999,990') AS prior_year_revenue,
    ROUND(
        ((annual_revenue - prior_year_revenue)::numeric / NULLIF(prior_year_revenue, 0)) * 100,
        2
    ) AS revenue_growth_pct,
    TO_CHAR(annual_tickets, 'FM999,999,999,990') AS annual_tickets,
    ROUND(
        ((annual_tickets - prior_year_tickets)::numeric / NULLIF(prior_year_tickets, 0)) * 100,
        2
    ) AS ticket_growth_pct
FROM market_trends
WHERE prior_year_revenue IS NOT NULL
ORDER BY
    year DESC,
    revenue_growth_pct DESC NULLS LAST
LIMIT 50;


/* ============================================================================
   QUERY 3
   Purpose: Calculate three-month moving averages for theater attendance and
            operating revenue by city.
   Techniques: CTEs, joins, aggregate functions, time-series moving average window
               function, DATE_TRUNC, date formatting.
   Interpretation / policy implication:
            Moving averages reduce monthly noise and make demand trends easier to
            observe. Cities with sustained upward attendance trends may justify
            added showtimes or facility investment; cities with declining moving
            averages may need pricing, accessibility, or content-mix interventions.
============================================================================ */
WITH city_monthly_operations AS (
    SELECT
        DATE_TRUNC('month', dt.full_date)::date AS month_start,
        INITCAP(TRIM(dth.location_city)) AS city,
        SUM(fto.attendance) AS monthly_attendance,
        SUM(fto.revenue_est) AS monthly_revenue,
        ROUND(AVG(fto.capacity_pct)::numeric, 2) AS avg_capacity_pct
    FROM fact_theater_operations AS fto
        INNER JOIN dim_theater AS dth
            ON fto.theater_key = dth.theater_key
        INNER JOIN dim_time AS dt
            ON fto.time_key = dt.time_key
    WHERE dth.location_city IS NOT NULL
    GROUP BY
        DATE_TRUNC('month', dt.full_date)::date,
        INITCAP(TRIM(dth.location_city))
), moving_average_metrics AS (
    SELECT
        month_start,
        city,
        monthly_attendance,
        monthly_revenue,
        avg_capacity_pct,
        ROUND(
            AVG(monthly_attendance) OVER (
                PARTITION BY city
                ORDER BY month_start
                ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
            )::numeric,
            2
        ) AS three_month_attendance_ma,
        ROUND(
            AVG(monthly_revenue) OVER (
                PARTITION BY city
                ORDER BY month_start
                ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
            )::numeric,
            2
        ) AS three_month_revenue_ma
    FROM city_monthly_operations
)
SELECT
    TO_CHAR(month_start, 'YYYY-MM') AS month,
    city,
    TO_CHAR(monthly_attendance, 'FM999,999,999,990') AS monthly_attendance,
    TO_CHAR(three_month_attendance_ma, 'FM999,999,999,990.00') AS three_month_attendance_ma,
    TO_CHAR(monthly_revenue, 'FM$999,999,999,990') AS monthly_revenue,
    TO_CHAR(three_month_revenue_ma, 'FM$999,999,999,990.00') AS three_month_revenue_ma,
    avg_capacity_pct
FROM moving_average_metrics
ORDER BY
    city,
    month_start;


/* ============================================================================
   QUERY 4
   Purpose: Track cumulative theater revenue and attendance over time by theater.
   Techniques: CTEs, joins, aggregate functions, running total window functions,
               filtering, date formatting.
   Interpretation / policy implication:
            Running totals show how quickly each theater contributes to yearly
            operating outcomes. Theaters that reach high cumulative attendance early
            may be anchors for local cultural activity; theaters with slow cumulative
            growth may need operational support or programming changes.
============================================================================ */
WITH theater_weekly_operations AS (
    SELECT
        dth.theater_name,
        INITCAP(TRIM(dth.location_city)) AS city,
        dt.year,
        dt.full_date,
        SUM(fto.revenue_est) AS weekly_revenue,
        SUM(fto.attendance) AS weekly_attendance
    FROM fact_theater_operations AS fto
        INNER JOIN dim_theater AS dth
            ON fto.theater_key = dth.theater_key
        INNER JOIN dim_time AS dt
            ON fto.time_key = dt.time_key
    GROUP BY
        dth.theater_name,
        INITCAP(TRIM(dth.location_city)),
        dt.year,
        dt.full_date
), running_totals AS (
    SELECT
        theater_name,
        city,
        year,
        full_date,
        weekly_revenue,
        weekly_attendance,
        SUM(weekly_revenue) OVER (
            PARTITION BY theater_name, year
            ORDER BY full_date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS running_year_revenue,
        SUM(weekly_attendance) OVER (
            PARTITION BY theater_name, year
            ORDER BY full_date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS running_year_attendance
    FROM theater_weekly_operations
)
SELECT
    theater_name,
    city,
    year,
    TO_CHAR(full_date, 'YYYY-MM-DD') AS week_start_date,
    TO_CHAR(weekly_revenue, 'FM$999,999,999,990') AS weekly_revenue,
    TO_CHAR(running_year_revenue, 'FM$999,999,999,990') AS running_year_revenue,
    TO_CHAR(weekly_attendance, 'FM999,999,999,990') AS weekly_attendance,
    TO_CHAR(running_year_attendance, 'FM999,999,999,990') AS running_year_attendance
FROM running_totals
WHERE running_year_revenue > 0
ORDER BY
    year DESC,
    theater_name,
    full_date;


/* ============================================================================
   QUERY 5
   Purpose: Combine movie-market revenue and theater-operation revenue into one
            city/market demand signal, then rank high-demand areas.
   Techniques: Temporary table, UNION ALL set operator, CTEs, joins, aggregate
               functions, ranking window function, GROUP BY, HAVING.
   Interpretation / policy implication:
            This query creates a combined demand signal from both movie performance
            and theater operations. Areas with high combined revenue are candidates
            for marketing priority, infrastructure investment, or additional film
            programming support.
============================================================================ */
DROP TABLE IF EXISTS temp_city_revenue_signal;

CREATE TEMP TABLE temp_city_revenue_signal AS
SELECT
    'movie_market_revenue' AS source_type,
    dm.market_name AS area_name,
    dt.year,
    SUM(fmp.box_office_rev) AS revenue_amount,
    SUM(fmp.tickets_sold) AS audience_count
FROM fact_movie_performance AS fmp
    INNER JOIN dim_market AS dm
        ON fmp.market_key = dm.market_key
    INNER JOIN dim_time AS dt
        ON fmp.time_key = dt.time_key
GROUP BY
    dm.market_name,
    dt.year

UNION ALL

SELECT
    'theater_operation_revenue' AS source_type,
    INITCAP(TRIM(dth.location_city)) AS area_name,
    dt.year,
    SUM(fto.revenue_est) AS revenue_amount,
    SUM(fto.attendance) AS audience_count
FROM fact_theater_operations AS fto
    INNER JOIN dim_theater AS dth
        ON fto.theater_key = dth.theater_key
    INNER JOIN dim_time AS dt
        ON fto.time_key = dt.time_key
WHERE dth.location_city IS NOT NULL
GROUP BY
    INITCAP(TRIM(dth.location_city)),
    dt.year;

WITH combined_area_signal AS (
    SELECT
        area_name,
        year,
        COUNT(DISTINCT source_type) AS number_of_sources,
        SUM(revenue_amount) AS combined_revenue,
        SUM(audience_count) AS combined_audience
    FROM temp_city_revenue_signal
    GROUP BY
        area_name,
        year
    HAVING COUNT(DISTINCT source_type) >= 1
), ranked_area_signal AS (
    SELECT
        area_name,
        year,
        number_of_sources,
        combined_revenue,
        combined_audience,
        RANK() OVER (
            PARTITION BY year
            ORDER BY combined_revenue DESC
        ) AS area_revenue_rank
    FROM combined_area_signal
)
SELECT
    area_name,
    year,
    number_of_sources,
    TO_CHAR(combined_revenue, 'FM$999,999,999,990') AS combined_revenue,
    TO_CHAR(combined_audience, 'FM999,999,999,990') AS combined_audience,
    area_revenue_rank
FROM ranked_area_signal
WHERE area_revenue_rank <= 10
ORDER BY
    year DESC,
    area_revenue_rank;


/* ============================================================================
   QUERY 6
   Purpose: Rank companies by annual revenue, profit, and profit margin within
            each industry sector.
   Techniques: CTEs, joins, aggregate functions, ranking window functions,
               value formatting, filtering.
   Interpretation / policy implication:
            This output identifies financially strong and weak industry actors.
            Managers can benchmark companies against peers, while policy analysts
            can see which sectors have stronger capacity to invest in theatrical
            distribution, local employment, or content production.
============================================================================ */
WITH company_year_metrics AS (
    SELECT
        dc.sector,
        dc.company_name,
        dt.year,
        SUM(fim.annual_revenue) AS annual_revenue,
        SUM(fim.annual_profit) AS annual_profit,
        ROUND(
            (SUM(fim.annual_profit)::numeric / NULLIF(SUM(fim.annual_revenue), 0)) * 100,
            2
        ) AS profit_margin_pct
    FROM fact_industry_metrics AS fim
        INNER JOIN dim_company AS dc
            ON fim.company_key = dc.company_key
        INNER JOIN dim_time AS dt
            ON fim.time_key = dt.time_key
    GROUP BY
        dc.sector,
        dc.company_name,
        dt.year
), ranked_companies AS (
    SELECT
        sector,
        company_name,
        year,
        annual_revenue,
        annual_profit,
        profit_margin_pct,
        DENSE_RANK() OVER (
            PARTITION BY sector, year
            ORDER BY annual_revenue DESC
        ) AS revenue_rank_in_sector,
        DENSE_RANK() OVER (
            PARTITION BY sector, year
            ORDER BY profit_margin_pct DESC NULLS LAST
        ) AS margin_rank_in_sector
    FROM company_year_metrics
)
SELECT
    sector,
    company_name,
    year,
    TO_CHAR(annual_revenue, 'FM$999,999,999,990') AS annual_revenue,
    TO_CHAR(annual_profit, 'FM$999,999,999,990') AS annual_profit,
    profit_margin_pct,
    revenue_rank_in_sector,
    margin_rank_in_sector
FROM ranked_companies
WHERE revenue_rank_in_sector <= 5
ORDER BY
    year DESC,
    sector,
    revenue_rank_in_sector;


/* ============================================================================
   QUERY 7 
   Purpose: Use LEAD to identify cities where theater attendance increases
            in the next reporting period.
   Techniques: CTEs, joins, aggregate functions, LEAD value window function,
               filtering, date formatting.
   Interpretation / policy implication:
            This query highlights cities where audience demand is rising from one
            reporting period to the next. Theater managers can use these results
            to plan staffing, showtimes, and local marketing before demand peaks.
============================================================================ */

WITH city_weekly AS (
    SELECT
        INITCAP(TRIM(dth.location_city)) AS city,
        dt.full_date AS week_start_date,
        SUM(fto.attendance) AS weekly_attendance,
        ROUND(AVG(fto.capacity_pct)::numeric, 2) AS avg_capacity_pct
    FROM fact_theater_operations AS fto
        INNER JOIN dim_theater AS dth
            ON fto.theater_key = dth.theater_key
        INNER JOIN dim_time AS dt
            ON fto.time_key = dt.time_key
	WHERE dth.location_city IS NOT NULL
    GROUP BY
        INITCAP(TRIM(dth.location_city)),
        dt.full_date
), city_leads AS (
    SELECT
        city,
        week_start_date,
        weekly_attendance,
        avg_capacity_pct,
        LEAD(weekly_attendance) OVER (
            PARTITION BY city
            ORDER BY week_start_date
        ) AS next_period_attendance,
        LEAD(avg_capacity_pct) OVER (
            PARTITION BY city
            ORDER BY week_start_date
        ) AS next_period_capacity_pct
    FROM city_weekly
)
SELECT
    city,
    TO_CHAR(week_start_date, 'YYYY-MM-DD') AS week_start_date,
    TO_CHAR(weekly_attendance, 'FM999,999,999,990') AS weekly_attendance,
    avg_capacity_pct,
    TO_CHAR(next_period_attendance, 'FM999,999,999,990') AS next_period_attendance,
    next_period_capacity_pct,
    ROUND(
        ((next_period_attendance - weekly_attendance)::numeric / NULLIF(weekly_attendance, 0)) * 100,
        2
    ) AS next_period_attendance_growth_pct
FROM city_leads
WHERE next_period_attendance IS NOT NULL
  AND next_period_attendance > weekly_attendance
ORDER BY
    next_period_attendance_growth_pct DESC NULLS LAST,
    city
LIMIT 75;

/* ============================================================================
   QUERY 8
   Purpose: Calculate a four-period moving average for company revenue and profit
         based on the available time records.
   Techniques: CTEs, joins, aggregate functions, moving average window functions,
               DATE_TRUNC, formatting.
   Interpretation / policy implication:
            Moving averages reveal stable company-level financial direction rather
            than one-period volatility. Companies with improving four-period moving
            averages may be better positioned to support theatrical distribution
            or technology investment.
============================================================================ */
WITH company_quarter_metrics AS (
    SELECT
        dc.company_name,
        dc.sector,
        DATE_TRUNC('quarter', dt.full_date)::date AS quarter_start,
        SUM(fim.annual_revenue) AS quarter_revenue,
        SUM(fim.annual_profit) AS quarter_profit
    FROM fact_industry_metrics AS fim
        INNER JOIN dim_company AS dc
            ON fim.company_key = dc.company_key
        INNER JOIN dim_time AS dt
            ON fim.time_key = dt.time_key
    GROUP BY
        dc.company_name,
        dc.sector,
        DATE_TRUNC('quarter', dt.full_date)::date
), moving_company_metrics AS (
    SELECT
        company_name,
        sector,
        quarter_start,
        quarter_revenue,
        quarter_profit,
        ROUND(
            AVG(quarter_revenue) OVER (
                PARTITION BY company_name
                ORDER BY quarter_start
                ROWS BETWEEN 3 PRECEDING AND CURRENT ROW
            )::numeric,
            2
        ) AS four_quarter_revenue_ma,
        ROUND(
            AVG(quarter_profit) OVER (
                PARTITION BY company_name
                ORDER BY quarter_start
                ROWS BETWEEN 3 PRECEDING AND CURRENT ROW
            )::numeric,
            2
        ) AS four_quarter_profit_ma
    FROM company_quarter_metrics
)
SELECT
    company_name,
    sector,
    TO_CHAR(quarter_start, 'YYYY-"Q"Q') AS quarter,
    TO_CHAR(quarter_revenue, 'FM$999,999,999,990') AS quarter_revenue,
    TO_CHAR(four_quarter_revenue_ma, 'FM$999,999,999,990.00') AS four_quarter_revenue_ma,
    TO_CHAR(quarter_profit, 'FM$999,999,999,990') AS quarter_profit,
    TO_CHAR(four_quarter_profit_ma, 'FM$999,999,999,990.00') AS four_quarter_profit_ma
FROM moving_company_metrics
ORDER BY
    company_name,
    quarter_start;


/* ============================================================================
   QUERY 9
   Purpose: Calculate running market share by year and market, showing how each
            market contributes to cumulative annual box-office revenue.
   Techniques: CTEs, joins, aggregate functions, running total window function,
               percentage calculation, ordering, formatting.
   Interpretation / policy implication:
            This helps identify whether annual revenue is concentrated in a small
            number of markets. High cumulative concentration may indicate geographic
            inequality in movie access or marketing investment.
============================================================================ */
WITH market_year_revenue AS (
    SELECT
        dt.year,
        dm.market_name,
        SUM(fmp.box_office_rev) AS market_revenue,
        SUM(SUM(fmp.box_office_rev)) OVER (
            PARTITION BY dt.year
        ) AS total_year_revenue
    FROM fact_movie_performance AS fmp
        INNER JOIN dim_market AS dm
            ON fmp.market_key = dm.market_key
        INNER JOIN dim_time AS dt
            ON fmp.time_key = dt.time_key
    GROUP BY
        dt.year,
        dm.market_name
), market_share AS (
    SELECT
        year,
        market_name,
        market_revenue,
        total_year_revenue,
        ROUND(
            (market_revenue::numeric / NULLIF(total_year_revenue, 0)) * 100,
            2
        ) AS market_share_pct
    FROM market_year_revenue
), running_market_share AS (
    SELECT
        year,
        market_name,
        market_revenue,
        total_year_revenue,
        market_share_pct,
        SUM(market_revenue) OVER (
            PARTITION BY year
            ORDER BY market_revenue DESC
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS running_revenue_by_rank
    FROM market_share
)
SELECT
    year,
    market_name,
    TO_CHAR(market_revenue, 'FM$999,999,999,990') AS market_revenue,
    market_share_pct,
    TO_CHAR(running_revenue_by_rank, 'FM$999,999,999,990') AS running_revenue_by_rank,
    ROUND(
        (running_revenue_by_rank::numeric / NULLIF(total_year_revenue, 0)) * 100,
        2
    ) AS running_market_share_pct
FROM running_market_share
ORDER BY
    year DESC,
    running_revenue_by_rank;


/* ============================================================================
   QUERY 10
   Purpose: Identify theaters that are both above-average in revenue and
            above-average in attendance, while excluding records with invalid
            or missing operational values.
   Techniques: Temporary table, INTERSECT and EXCEPT set operators, CTEs, joins,
               aggregate functions, filtering, ranking.
   Interpretation / policy implication:
            This query identifies theaters that perform well on both financial
            and audience-demand measures. These theaters can be used as benchmarks
            for programming, staffing, and local marketing decisions, while lower
            performing theaters may need targeted operational review.
============================================================================ */

DROP TABLE IF EXISTS temp_theater_year_metrics;

CREATE TEMP TABLE temp_theater_year_metrics AS
SELECT
    dth.theater_name,
    INITCAP(TRIM(dth.location_city)) AS city,
    dt.year,
    SUM(fto.revenue_est) AS annual_theater_revenue,
    SUM(fto.attendance) AS annual_attendance,
    ROUND(AVG(fto.capacity_pct)::numeric, 2) AS avg_capacity_pct
FROM fact_theater_operations AS fto
    INNER JOIN dim_theater AS dth
        ON fto.theater_key = dth.theater_key
    INNER JOIN dim_time AS dt
        ON fto.time_key = dt.time_key
GROUP BY
    dth.theater_name,
    INITCAP(TRIM(dth.location_city)),
    dt.year;

WITH revenue_benchmark AS (
    SELECT AVG(annual_theater_revenue) AS avg_revenue
    FROM temp_theater_year_metrics
), attendance_benchmark AS (
    SELECT AVG(annual_attendance) AS avg_attendance
    FROM temp_theater_year_metrics
), above_avg_revenue_theaters AS (
    SELECT theater_name, city, year
    FROM temp_theater_year_metrics
    WHERE annual_theater_revenue >= (
        SELECT avg_revenue FROM revenue_benchmark
    )
), above_avg_attendance_theaters AS (
    SELECT theater_name, city, year
    FROM temp_theater_year_metrics
    WHERE annual_attendance >= (
        SELECT avg_attendance FROM attendance_benchmark
    )
), invalid_theater_records AS (
    SELECT theater_name, city, year
    FROM temp_theater_year_metrics
    WHERE annual_theater_revenue IS NULL
       OR annual_attendance IS NULL
       OR avg_capacity_pct IS NULL
       OR annual_theater_revenue <= 0
       OR annual_attendance <= 0
), balanced_theaters AS (
    SELECT theater_name, city, year
    FROM above_avg_revenue_theaters

    INTERSECT

    SELECT theater_name, city, year
    FROM above_avg_attendance_theaters

    EXCEPT

    SELECT theater_name, city, year
    FROM invalid_theater_records
), ranked_balanced_theaters AS (
    SELECT
        ttym.theater_name,
        ttym.city,
        ttym.year,
        ttym.annual_theater_revenue,
        ttym.annual_attendance,
        ttym.avg_capacity_pct,
        RANK() OVER (
            PARTITION BY ttym.year
            ORDER BY ttym.annual_theater_revenue DESC, ttym.annual_attendance DESC
        ) AS balanced_performance_rank
    FROM temp_theater_year_metrics AS ttym
        INNER JOIN balanced_theaters AS bt
            ON ttym.theater_name = bt.theater_name
            AND ttym.city = bt.city
            AND ttym.year = bt.year
)
SELECT
    theater_name,
    city,
    year,
    TO_CHAR(annual_theater_revenue, 'FM$999,999,999,990') AS annual_theater_revenue,
    TO_CHAR(annual_attendance, 'FM999,999,999,990') AS annual_attendance,
    avg_capacity_pct,
    balanced_performance_rank
FROM ranked_balanced_theaters
WHERE balanced_performance_rank <= 20
ORDER BY
    year DESC,
    balanced_performance_rank;
	
	/* ============================================================================
   QUERY 11 - HYBRID SEARCH FOR SEMANTICALLY RELEVANT MOVIE DEMAND
   Purpose: Use PostgreSQL full-text search as a hybrid search method to identify
            movies related to family-friendly, comedy, drama, or action
            themes, then rank the highest-demand movies by market-year.
   Techniques: CTEs, multiple joins, aggregate functions, PostgreSQL full-text
               search, ts_rank_cd relevance scoring, hybrid relevance/revenue
               ranking, string/date formatting, filtering, LIMIT.
   Interpretation / policy implication:
            This query combines semantic text relevance with revenue and ticket
            demand. Decision makers can use it to identify which thematically
            relevant movies have the strongest audience demand in each market,
            supporting programming, marketing, and audience development decisions.
============================================================================ */

WITH search_parameters AS (
    SELECT websearch_to_tsquery('english', 'musical OR family OR comedy OR drama') AS search_query
), searchable_productions AS (
    SELECT
        fmp.movie_key,
        fmp.time_key,
        fmp.market_key,
        to_tsvector(
            'english',
            COALESCE(dmv.movie_title, '') || ' ' ||
            COALESCE(dmv.synopsis_text, '') || ' ' ||
            COALESCE(dmv.content_type, '') || ' ' ||
            COALESCE(dmv.content_rating, '')
        ) AS production_search_vector
    FROM fact_movie_performance AS fmp
        INNER JOIN dim_movie AS dmv
            ON fmp.movie_key = dmv.movie_key
), semantic_market_year AS (
    SELECT
        dt.year,
        dm.market_name,
        INITCAP(TRIM(dmv.movie_title)) AS production_title,
        COALESCE(NULLIF(TRIM(dmv.content_type), ''), 'Unknown') AS production_type,
        COALESCE(NULLIF(TRIM(dmv.content_rating), ''), 'Unrated') AS content_rating,
        ROUND(
            MAX(ts_rank_cd(sp.production_search_vector, prm.search_query))::numeric,
            4
        ) AS semantic_relevance_score,
        SUM(fmp.box_office_rev) AS total_revenue,
        SUM(fmp.tickets_sold) AS total_tickets
    FROM fact_movie_performance AS fmp
        INNER JOIN dim_movie AS dmv
            ON fmp.movie_key = dmv.movie_key
        INNER JOIN dim_market AS dm
            ON fmp.market_key = dm.market_key
        INNER JOIN dim_time AS dt
            ON fmp.time_key = dt.time_key
        INNER JOIN searchable_productions AS sp
            ON fmp.movie_key = sp.movie_key
            AND fmp.time_key = sp.time_key
            AND fmp.market_key = sp.market_key
        CROSS JOIN search_parameters AS prm
    WHERE
        sp.production_search_vector @@ prm.search_query
    GROUP BY
        dt.year,
        dm.market_name,
        INITCAP(TRIM(dmv.movie_title)),
        COALESCE(NULLIF(TRIM(dmv.content_type), ''), 'Unknown'),
        COALESCE(NULLIF(TRIM(dmv.content_rating), ''), 'Unrated')
    HAVING
        SUM(fmp.box_office_rev) > 0
        AND SUM(fmp.tickets_sold) > 0
), hybrid_ranked_results AS (
    SELECT
        year,
        market_name,
        production_title,
        production_type,
        content_rating,
        semantic_relevance_score,
        total_revenue,
        total_tickets,
        ROUND(
            (semantic_relevance_score * 100 + LN(1 + total_revenue))::numeric,
            4
        ) AS hybrid_score,
        DENSE_RANK() OVER (
            PARTITION BY year, market_name
            ORDER BY
                (semantic_relevance_score * 100 + LN(1 + total_revenue)) DESC,
                total_tickets DESC
        ) AS hybrid_rank_in_market_year
    FROM semantic_market_year
)
SELECT
    year,
    market_name,
    production_title,
    production_type,
    content_rating,
    semantic_relevance_score,
    TO_CHAR(total_revenue, 'FM$999,999,999,990') AS total_revenue,
    TO_CHAR(total_tickets, 'FM999,999,999,990') AS total_tickets,
    hybrid_score,
    hybrid_rank_in_market_year
FROM hybrid_ranked_results
WHERE hybrid_rank_in_market_year <= 10
ORDER BY
    year DESC,
    market_name,
    hybrid_rank_in_market_year
LIMIT 100;


/* ============================================================================
   QUERY 12 - HYBRID SEARCH TREND ANALYSIS FOR THEMATIC MOVIE DEMAND
   Purpose: Use hybrid search to isolate movies related to movie
            themes such as action, comedy, drama, and thriller, then calculate
            year-over-year market demand changes for those movies.
   Techniques: CTEs, multiple joins, aggregate functions, PostgreSQL full-text
               search, ts_rank_cd relevance scoring, LAG value window function,
               growth-rate calculation, ranking, date/value formatting, LIMIT.
   Interpretation / policy implication:
            This query shows whether semantically relevant movies are gaining
            or losing demand over time in each market. Positive growth may suggest
            audience interest that should be supported through targeted programming
            and promotion, while negative growth may indicate markets where outreach
            or content mix adjustments are needed.
============================================================================ */

WITH search_parameters AS (
    SELECT websearch_to_tsquery('english', 'musical OR play OR comedy OR drama') AS search_query
), matched_production_rows AS (
    SELECT
        dm.market_name,
        dt.year,
        fmp.box_office_rev,
        fmp.tickets_sold,
        INITCAP(TRIM(dmv.movie_title)) AS production_title,
        ts_rank_cd(
            to_tsvector(
                'english',
                COALESCE(dmv.movie_title, '') || ' ' ||
                COALESCE(dmv.synopsis_text, '') || ' ' ||
                COALESCE(dmv.content_type, '') || ' ' ||
                COALESCE(dmv.content_rating, '')
            ),
            prm.search_query
        ) AS semantic_relevance_score
    FROM fact_movie_performance AS fmp
        INNER JOIN dim_movie AS dmv
            ON fmp.movie_key = dmv.movie_key
        INNER JOIN dim_market AS dm
            ON fmp.market_key = dm.market_key
        INNER JOIN dim_time AS dt
            ON fmp.time_key = dt.time_key
        CROSS JOIN search_parameters AS prm
    WHERE
        to_tsvector(
            'english',
            COALESCE(dmv.movie_title, '') || ' ' ||
            COALESCE(dmv.synopsis_text, '') || ' ' ||
            COALESCE(dmv.content_type, '') || ' ' ||
            COALESCE(dmv.content_rating, '')
        ) @@ prm.search_query
), annual_semantic_market AS (
    SELECT
        market_name,
        year,
        COUNT(DISTINCT production_title) AS matched_production_count,
        ROUND(AVG(semantic_relevance_score)::numeric, 4) AS avg_semantic_relevance_score,
        SUM(box_office_rev) AS thematic_revenue,
        SUM(tickets_sold) AS thematic_tickets
    FROM matched_production_rows
    GROUP BY
        market_name,
        year
    HAVING
        SUM(box_office_rev) > 0
        AND SUM(tickets_sold) > 0
), semantic_market_trends AS (
    SELECT
        market_name,
        year,
        matched_production_count,
        avg_semantic_relevance_score,
        thematic_revenue,
        thematic_tickets,
        LAG(thematic_revenue) OVER (
            PARTITION BY market_name
            ORDER BY year
        ) AS prior_year_thematic_revenue,
        LAG(thematic_tickets) OVER (
            PARTITION BY market_name
            ORDER BY year
        ) AS prior_year_thematic_tickets
    FROM annual_semantic_market
), ranked_semantic_growth AS (
    SELECT
        market_name,
        year,
        matched_production_count,
        avg_semantic_relevance_score,
        thematic_revenue,
        thematic_tickets,
        prior_year_thematic_revenue,
        prior_year_thematic_tickets,
        ROUND(
            ((thematic_revenue - prior_year_thematic_revenue)::numeric /
             NULLIF(prior_year_thematic_revenue, 0)) * 100,
            2
        ) AS thematic_revenue_growth_pct,
        ROUND(
            ((thematic_tickets - prior_year_thematic_tickets)::numeric /
             NULLIF(prior_year_thematic_tickets, 0)) * 100,
            2
        ) AS thematic_ticket_growth_pct,
        DENSE_RANK() OVER (
            PARTITION BY year
            ORDER BY
                ((thematic_revenue - prior_year_thematic_revenue)::numeric /
                 NULLIF(prior_year_thematic_revenue, 0)) DESC NULLS LAST
        ) AS thematic_growth_rank
    FROM semantic_market_trends
    WHERE prior_year_thematic_revenue IS NOT NULL
)
SELECT
    market_name,
    year,
    matched_production_count,
    avg_semantic_relevance_score,
    TO_CHAR(thematic_revenue, 'FM$999,999,999,990') AS thematic_revenue,
    TO_CHAR(prior_year_thematic_revenue, 'FM$999,999,999,990') AS prior_year_thematic_revenue,
    thematic_revenue_growth_pct,
    TO_CHAR(thematic_tickets, 'FM999,999,999,990') AS thematic_tickets,
    thematic_ticket_growth_pct,
    thematic_growth_rank
FROM ranked_semantic_growth
WHERE thematic_growth_rank <= 10
ORDER BY
    year DESC,
    thematic_growth_rank,
    market_name;
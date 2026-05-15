-- AOV chort分析
-- 1. 每个用户首次购买月份
WITH RECURSIVE first_purchase AS (
    SELECT
        customer_id,
        strftime('%Y-%m', MIN(order_date)) AS cohort_month
    FROM orders
    GROUP BY customer_id),

-- 2. 每个用户每月AOV
customer_monthly_aov AS (
    SELECT
        customer_id,
        strftime('%Y-%m', order_date) AS activity_month,
        COUNT(DISTINCT order_id) AS order_count,
        SUM(total_amount_usd) AS total_revenue,
        ROUND(AVG(total_amount_usd),2) AS aov
    FROM orders
    GROUP BY customer_id, strftime('%Y-%m', order_date)),

-- 3. cohort基数
cohort_size AS (
    SELECT
        cohort_month,
        COUNT(DISTINCT customer_id) AS cohort_size
    FROM first_purchase
    GROUP BY cohort_month),

-- 4. 数据集最后月份
dataset_max AS (
    SELECT
        MAX(strftime('%Y-%m', order_date)) AS max_month
    FROM orders),

-- 5. 连续月份序列
month_sequence(month_number) AS (
    SELECT 0
    UNION ALL
    SELECT month_number + 1
    FROM month_sequence
    WHERE month_number < 120),

-- 6. 完整cohort生命周期
cohort_grid AS (
    SELECT
        cs.cohort_month,
        ms.month_number
    FROM cohort_size cs
    CROSS JOIN month_sequence ms
    CROSS JOIN dataset_max dm
    WHERE ms.month_number <=
    (
        (
            CAST(substr(dm.max_month,1,4) AS INTEGER)
            -
            CAST(substr(cs.cohort_month,1,4) AS INTEGER)
        ) * 12
 +

        (
            CAST(substr(dm.max_month,6,2) AS INTEGER)
            -
            CAST(substr(cs.cohort_month,6,2) AS INTEGER)
        )
    )
),

-- 7. 用户AOV映射到完整生命周期
cohort_aov_base AS (
    SELECT
        cg.cohort_month,
        cg.month_number,
        fp.customer_id,
        cma.aov
    FROM cohort_grid cg
    JOIN first_purchase fp
        ON cg.cohort_month = fp.cohort_month
    LEFT JOIN customer_monthly_aov cma
        ON fp.customer_id = cma.customer_id
        AND
        (
            (
                CAST(substr(cma.activity_month,1,4) AS INTEGER)
                -
                CAST(substr(fp.cohort_month,1,4) AS INTEGER)
            ) * 12
            +
            (
                CAST(substr(cma.activity_month,6,2) AS INTEGER)
                -
                CAST(substr(fp.cohort_month,6,2) AS INTEGER)
            )
        ) = cg.month_number
),

-- 8. 为中位数排序
aov_with_row_num AS (
    SELECT
        cohort_month,
        month_number,
        aov,
        ROW_NUMBER() OVER (
            PARTITION BY cohort_month, month_number
            ORDER BY aov) AS row_num,
        COUNT(aov) OVER (PARTITION BY cohort_month, month_number) AS total_count
    FROM cohort_aov_base
    WHERE aov IS NOT NULL),

-- 9. 计算中位数
median_aov AS (
    SELECT
        cohort_month,
        month_number,
        AVG(aov) AS median_aov
    FROM aov_with_row_num
    WHERE row_num IN (
        (total_count + 1) / 2,
        (total_count + 2) / 2)
    GROUP BY
        cohort_month,
        month_number),

-- 10. 聚合AOV指标
aov_summary AS (
    SELECT
        cohort_month,
        month_number,
        COUNT(DISTINCT customer_id) FILTER (
            WHERE aov IS NOT NULL ) AS active_customers,

        ROUND(AVG(aov),2) AS avg_aov,
        ROUND(MIN(aov),2) AS min_aov,
        ROUND(MAX(aov),2) AS max_aov
    FROM cohort_aov_base
    GROUP BY cohort_month, month_number)

-- 最终结果
SELECT
    s.cohort_month,
    s.month_number,
    s.active_customers,
    s.avg_aov,
    ROUND(m.median_aov,2) AS median_aov,
    s.min_aov,
    s.max_aov,
    ROUND(100.0 *
s.avg_aov /
FIRST_VALUE(s.avg_aov)OVER (PARTITION BY s.cohort_month ORDER BY s.month_number)
    ,2) AS aov_index,
    CASE
        WHEN s.avg_aov > m.median_aov * 1.2
        THEN '右偏（高客单价拉高均值）'
        WHEN m.median_aov > s.avg_aov * 1.2
        THEN '左偏（低客单价拉低均值）'
        ELSE '正态分布'
    END AS distribution_type
FROM aov_summary s
LEFT JOIN median_aov m
    ON s.cohort_month = m.cohort_month
    AND s.month_number = m.month_number
ORDER BY
    s.cohort_month, s.month_number;

-- Retention cohort分析
-- 1. 每个用户首次购买月份
WITH RECURSIVE first_purchase AS (
    SELECT
        customer_id,
        strftime('%Y-%m', MIN(order_date)) AS cohort_month
    FROM orders
    GROUP BY customer_id),

-- 2. 用户每月活跃记录
customer_activity AS (
    SELECT DISTINCT
        customer_id,
        strftime('%Y-%m', order_date) AS activity_month
    FROM orders),

-- 3. 数据集最后月份
dataset_max AS (
    SELECT
        MAX(strftime('%Y-%m', order_date)) AS max_month
    FROM orders),

-- 4. 生成连续月份序列
month_sequence(month_number) AS (
    SELECT 0
    UNION ALL
    SELECT month_number + 1
    FROM month_sequence
WHERE month_number < 120),

-- 5. cohort基数
cohort_size AS (
    SELECT
        cohort_month,
        COUNT(DISTINCT customer_id) AS total_customers
    FROM first_purchase
    GROUP BY cohort_month),

-- 6. 构造完整cohort生命周期
cohort_grid AS
(
    SELECT
        cs.cohort_month,
        ms.month_number
    FROM cohort_size cs
    CROSS JOIN month_sequence ms
    CROSS JOIN dataset_max dm
    WHERE ms.month_number <=
(  (CAST(substr(dm.max_month,1,4) AS INTEGER)-
CAST(substr(cs.cohort_month,1,4) AS INTEGER) ) * 12 +
(  CAST(substr(dm.max_month,6,2) AS INTEGER)-
CAST(substr(cs.cohort_month,6,2) AS INTEGER) ) )
)

-- 7. 最终聚合
SELECT
    cg.cohort_month,
    cg.month_number,
    COUNT(DISTINCT ca.customer_id) AS retained_customers,
    cs.total_customers,
ROUND(100.0 * COUNT(DISTINCT ca.customer_id)/ cs.total_customers,2) AS retention_rate_pct,
    LAG(COUNT(DISTINCT ca.customer_id))OVER (PARTITION BY cg.cohort_month ORDER BY cg.month_number ) AS prev_month_retained,
    ROUND(100.0 *(LAG(COUNT(DISTINCT ca.customer_id))OVER (PARTITION BY cg.cohort_month
ORDER BY cg.month_number) - COUNT(DISTINCT ca.customer_id))/
        NULLIF( LAG(COUNT(DISTINCT ca.customer_id))OVER (PARTITION BY cg.cohort_month
ORDER BY cg.month_number), 0) ,2) AS churn_rate_pct
FROM cohort_grid cg
JOIN first_purchase fp
    ON cg.cohort_month = fp.cohort_month
LEFT JOIN customer_activity ca
    ON fp.customer_id = ca.customer_id
    AND ((CAST(substr(ca.activity_month,1,4) AS INTEGER)- CAST(substr(fp.cohort_month,1,4) AS INTEGER)) * 12 +(CAST(substr(ca.activity_month,6,2) AS INTEGER)-CAST(substr(fp.cohort_month,6,2) AS INTEGER)) ) = cg.month_number
JOIN cohort_size cs
    ON cg.cohort_month = cs.cohort_month
GROUP BY cg.cohort_month, cg.month_number,cs.total_customers
ORDER BY cg.cohort_month,cg.month_number;

-- Revenue cohort分析
-- 1. 每个用户首次购买月份
WITH RECURSIVE first_purchase AS (
    SELECT
        customer_id,
        strftime('%Y-%m', MIN(order_date)) AS cohort_month
    FROM orders
    GROUP BY customer_id),

-- 2. 每个用户每月收入
customer_monthly_revenue AS (
    SELECT
        customer_id,
        strftime('%Y-%m', order_date) AS activity_month,
        SUM(total_amount_usd) AS monthly_revenue,
        COUNT(DISTINCT order_id) AS monthly_orders
    FROM orders
    GROUP BY customer_id, strftime('%Y-%m', order_date)),

-- 3. cohort基数
cohort_size AS (
    SELECT
        cohort_month,
        COUNT(DISTINCT customer_id) AS cohort_size
    FROM first_purchase
    GROUP BY cohort_month),

-- 4. 数据集最后月份
dataset_max AS (
    SELECT
        MAX(strftime('%Y-%m', order_date)) AS max_month
    FROM orders),

-- 5. 连续月份序列
month_sequence(month_number) AS (
    SELECT 0
    UNION ALL
    SELECT month_number + 1
    FROM month_sequence
    WHERE month_number < 120),

-- 6. 构造完整 cohort 生命周期
cohort_grid AS (
    SELECT
        cs.cohort_month,
        ms.month_number
    FROM cohort_size cs
    CROSS JOIN month_sequence ms
    CROSS JOIN dataset_max dm
    WHERE ms.month_number <=
    (
        (
            CAST(substr(dm.max_month,1,4) AS INTEGER)
            -
            CAST(substr(cs.cohort_month,1,4) AS INTEGER)
        ) * 12
        +
        (
            CAST(substr(dm.max_month,6,2) AS INTEGER)
            -
            CAST(substr(cs.cohort_month,6,2) AS INTEGER)
        )
    )
)

-- 7. 最终 Revenue Cohort
SELECT
    cg.cohort_month,
    cg.month_number,
    COUNT(DISTINCT cmr.customer_id) AS active_customers,
    ROUND(COALESCE(SUM(cmr.monthly_revenue),0),2) AS total_revenue,
    ROUND(AVG(cmr.monthly_revenue),2) AS avg_revenue_per_active_customer,
    ROUND(AVG(cmr.monthly_orders),2) AS avg_orders_per_active_customer,
    -- 累计LTV
    ROUND(
        SUM(COALESCE(SUM(cmr.monthly_revenue),0))
        OVER (PARTITION BY cg.cohort_month ORDER BY cg.month_number
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW),2) AS cumulative_ltv,
    cs.cohort_size,
    -- 每用户累计LTV（ARPU/LTV）
    ROUND(
        SUM(COALESCE(SUM(cmr.monthly_revenue),0))
        OVER (PARTITION BY cg.cohort_month ORDER BY cg.month_number
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)/ cs.cohort_size
        ,2) AS cumulative_ltv_per_user
FROM cohort_grid cg
JOIN first_purchase fp
    ON cg.cohort_month = fp.cohort_month
LEFT JOIN customer_monthly_revenue cmr
    ON fp.customer_id = cmr.customer_id
    AND
    (
        (
            CAST(substr(cmr.activity_month,1,4) AS INTEGER)
            -
            CAST(substr(fp.cohort_month,1,4) AS INTEGER)
        ) * 12
        +
        (
            CAST(substr(cmr.activity_month,6,2) AS INTEGER)
            -
            CAST(substr(fp.cohort_month,6,2) AS INTEGER)
        )
    ) = cg.month_number
JOIN cohort_size cs
    ON cg.cohort_month = cs.cohort_month
GROUP BY cg.cohort_month, cg.month_number, cs.cohort_size
ORDER BY cg.cohort_month, cg.month_number;

-- Channel cohort分析
-- 1.获得每个客户首单信息
WITH first_order AS (
    SELECT
        customer_id,
        MIN(order_date) AS first_order_date
    FROM orders
    GROUP BY customer_id),

-- 2.合并三个表
first_order_detail AS (
    SELECT
        fo.customer_id,
        fo.first_order_date,
        c.acquisition_channel,
        MIN(o.total_amount_usd) AS first_order_amount
    FROM first_order fo
    JOIN orders o
        ON fo.customer_id = o.customer_id
       AND fo.first_order_date = o.order_date
    JOIN customers c
        ON fo.customer_id = c.customer_id
    GROUP BY fo.customer_id),

-- 3.每个客户的情况汇总
customer_lifecycle AS (
    SELECT
        customer_id,
        COUNT(*) AS total_orders,
        SUM(total_amount_usd) AS total_revenue,
        AVG(total_amount_usd) AS overall_aov,
        JULIANDAY(MAX(order_date)) - JULIANDAY(MIN(order_date)) AS lifetime_days,
        CASE
            WHEN COUNT(*) >= 2 THEN 1
            ELSE 0
        END AS is_repeat
    FROM orders
    GROUP BY customer_id)

-- 4.最后汇总
SELECT
    fod.acquisition_channel,
    COUNT(*) AS new_customers,
    ROUND(AVG(cl.is_repeat)*100,2) AS repeat_rate_pct,
    ROUND(AVG(fod.first_order_amount),2) AS first_order_aov,
    ROUND(AVG(cl.overall_aov),2) AS overall_aov,
    ROUND(AVG(cl.lifetime_days),2) AS avg_lifetime_days,
    ROUND(AVG(cl.total_revenue),2) AS avg_ltv
FROM first_order_detail fod
JOIN customer_lifecycle cl
    ON fod.customer_id = cl.customer_id
GROUP BY fod.acquisition_channel
ORDER BY avg_ltv DESC;
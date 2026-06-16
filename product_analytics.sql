-- Section 1 - Trial to Paid Conversion


-- a) Overall conversion rate
-- trial_accounts and converted_accounts built as separate CTEs for clarity
-- left join keeps trial accounts that never converted so they aren't silently dropped
with trial_accounts as (
    select distinct account_id
    from product_analytics.subscriptions
    where is_trial = 1
),
converted_accounts as (
    select distinct account_id
    from product_analytics.subscriptions
    where is_trial = 0
)
select
    count(t.account_id) as total_trial_accounts,
    count(c.account_id) as converted_accounts,
    count(t.account_id) - count(c.account_id) as unconverted_accounts,
    round(count(c.account_id) * 100.0
        / count(t.account_id), 2) as conversion_rate_pct
from trial_accounts t
left join converted_accounts c on t.account_id = c.account_id;


-- b) Conversion rate by referral source
-- inner join on trials keeps only accounts that had a trial
-- left join on converted keeps unmatched trials in the results with converted = 0
-- nullif prevents divide by zero if any referral source has no trial accounts
with trials as (
    select distinct account_id
    from product_analytics.subscriptions
    where is_trial = 1
),
converted as (
    select distinct account_id
    from product_analytics.subscriptions
    where is_trial = 0
)
select
    a.referral_source,
    count(t.account_id) as had_trial,
    count(c.account_id) as converted,
    round(count(c.account_id) * 100.0
        / nullif(count(t.account_id), 0), 2) as trial_conversion_rate_pct
from product_analytics.accounts a
join trials t on a.account_id = t.account_id
left join converted c on a.account_id = c.account_id
group by a.referral_source
order by trial_conversion_rate_pct desc, referral_source;


-- c) Days to convert
-- inner subquery takes min(paid start date) per account to get only the first paid subscription
-- without min(), every billing renewal row would be included and skew the average
-- DATE_DIFF replaces DATEDIFF (BigQuery syntax: DATE_DIFF(end, start, DAY))
select
    round(avg(diff_days), 1) as avg_days_to_convert,
    min(diff_days) as min_days,
    max(diff_days) as max_days
from (
    select
        t.account_id,
        DATE_DIFF(min(p.start_date), t.start_date, DAY) as diff_days
    from product_analytics.subscriptions t
    join product_analytics.subscriptions p
        on  t.account_id = p.account_id
        and t.is_trial   = 1
        and p.is_trial   = 0
        and p.start_date > t.start_date
    group by t.account_id, t.start_date
) days_calc;


-- Section 2 - Feature Adoption


-- a) Feature adoption rate
-- denominator pulls total paid subscriptions from subscriptions, not feature_usage
-- using feature_usage as the denominator would exclude subscriptions that never used a feature
-- and make every adoption rate look artificially high
-- error rate is total errors divided by total usage events per feature
select
    feature_name,
    is_beta_feature,
    count(distinct subscription_id) as adopting_subscriptions,
    round(count(distinct subscription_id) * 100.0
        / (select count(distinct subscription_id)
           from product_analytics.subscriptions
           where is_trial = 0), 2) as adoption_rate_pct,
    sum(usage_count) as total_usage_events,
    round(avg(usage_duration_secs) / 60, 1) as avg_duration_mins,
    round(sum(error_count) * 100.0
        / nullif(sum(usage_count), 0), 2) as error_rate_pct
from product_analytics.feature_usage
group by feature_name, is_beta_feature
order by adoption_rate_pct desc;


-- b) Feature breadth vs churn
-- paid_feature_usage filters feature_usage to paid subscriptions only
-- feature_breadth counts distinct features per account and assigns a bucket
-- churned_accounts uses churn_events as the single source of truth for churn
-- order by min(feature_count) ensures buckets appear in numerical order not alphabetical
with paid_feature_usage as (
    select
        s.account_id,
        fu.feature_name
    from product_analytics.feature_usage fu
    join product_analytics.subscriptions s on fu.subscription_id = s.subscription_id
    where s.is_trial = 0
),
feature_breadth as (
    select
        account_id,
        count(distinct feature_name) as feature_count,
        case
            when count(distinct feature_name) <= 3  then '1-3 features'
            when count(distinct feature_name) <= 7  then '4-7 features'
            when count(distinct feature_name) <= 12 then '8-12 features'
            else '13+ features'
        end as feature_breadth_bucket
    from paid_feature_usage
    group by account_id
),
churned_accounts as (
    select distinct account_id
    from product_analytics.churn_events
)
select
    feature_breadth_bucket,
    count(distinct fb.account_id) as total_accounts,
    sum(case when ca.account_id is not null then 1 else 0 end) as churned_accounts,
    round(sum(case when ca.account_id is not null then 1 else 0 end)
        * 100.0 / count(distinct fb.account_id), 2) as churn_rate_pct
from feature_breadth fb
left join churned_accounts ca on fb.account_id = ca.account_id
group by feature_breadth_bucket
order by min(feature_count);


-- Section 3 - Cohort Retention


-- a) Cohort retention grid
-- cohort_base finds each account's first paid subscription date and formats it as cohort month
-- monthly_activity calculates months elapsed between first paid date and each subsequent renewal
-- this works because subscriptions is a billing history table, each renewal is a new row
-- final select pivots into columns counting distinct accounts still active at M1, M3, M6, M12
-- FORMAT_DATE replaces DATE_FORMAT (BigQuery syntax)
-- DATE_DIFF replaces TIMESTAMPDIFF (BigQuery syntax: DATE_DIFF(end, start, MONTH))
with cohort_base as (
    select
        account_id,
        FORMAT_DATE('%Y-%m', min(start_date)) as cohort_month,
        min(start_date) as first_paid_date
    from product_analytics.subscriptions
    where is_trial = 0
    group by account_id
),
monthly_activity as (
    select
        cb.account_id,
        cb.cohort_month,
        DATE_DIFF(s.start_date, cb.first_paid_date, MONTH) as months_since_start
    from cohort_base cb
    join product_analytics.subscriptions s
        on  cb.account_id = s.account_id
        and s.is_trial    = 0
)
select
    cohort_month,
    count(distinct account_id) as cohort_size,
    count(distinct case when months_since_start = 1  then account_id end) as retained_m1,
    count(distinct case when months_since_start = 3  then account_id end) as retained_m3,
    count(distinct case when months_since_start = 6  then account_id end) as retained_m6,
    count(distinct case when months_since_start = 12 then account_id end) as retained_m12,
    round(count(distinct case when months_since_start = 1  then account_id end)
        * 100.0 / count(distinct account_id), 1) as m1_retention_pct,
    round(count(distinct case when months_since_start = 3  then account_id end)
        * 100.0 / count(distinct account_id), 1) as m3_retention_pct,
    round(count(distinct case when months_since_start = 6  then account_id end)
        * 100.0 / count(distinct account_id), 1) as m6_retention_pct,
    round(count(distinct case when months_since_start = 12 then account_id end)
        * 100.0 / count(distinct account_id), 1) as m12_retention_pct
from monthly_activity
group by cohort_month
order by cohort_month;


-- b) MRR trend by month
-- groups paid subscriptions by month and sums mrr
-- avg mrr alongside total mrr shows whether growth is coming from more accounts or higher spend
-- FORMAT_DATE replaces DATE_FORMAT (BigQuery syntax)
select
    FORMAT_DATE('%Y-%m', start_date) as month,
    count(distinct account_id) as active_accounts,
    sum(mrr_amount) as total_mrr,
    round(avg(mrr_amount), 0) as avg_mrr_per_account
from product_analytics.subscriptions
where is_trial = 0
group by FORMAT_DATE('%Y-%m', start_date)
order by month;


-- Section 4 - Churn Drivers


-- a) Churn by reason code
-- churn_total calculated once upfront so percentage is a simple division throughout
-- reactivation rate shows which churn reasons are most recoverable
with churn_total as (
    select count(*) as total
    from product_analytics.churn_events
)
select
    ce.reason_code,
    count(*) as churn_events,
    round(count(*) * 100.0 / ct.total, 2) as pct_of_churns,
    round(avg(ce.refund_amount_usd), 2) as avg_refund_usd,
    sum(ce.refund_amount_usd) as total_refund_usd,
    round(sum(case when ce.is_reactivation = 1 then 1 else 0 end)
        * 100.0 / count(*), 2) as reactivation_rate_pct
from product_analytics.churn_events ce
cross join churn_total ct
group by ce.reason_code, ct.total
order by churn_events desc;


-- b) Plan change pattern before churn
-- combines upgrade and downgrade flags into four mutually exclusive patterns
-- downgrade before churn is a classic signal of accounts trying to reduce spend before leaving
with churn_total as (
    select count(*) as total
    from product_analytics.churn_events
),
churn_classified as (
    select
        case
            when preceding_upgrade_flag   = 1 and preceding_downgrade_flag = 0 then 'Upgraded before churn'
            when preceding_downgrade_flag = 1 and preceding_upgrade_flag   = 0 then 'Downgraded before churn'
            when preceding_upgrade_flag   = 1 and preceding_downgrade_flag = 1 then 'Both'
            else 'No plan change'
        end as plan_change_pattern,
        refund_amount_usd
    from product_analytics.churn_events
)
select
    cc.plan_change_pattern,
    count(*) as churn_events,
    round(count(*) * 100.0 / ct.total, 2) as pct_of_churns,
    round(avg(cc.refund_amount_usd), 2) as avg_refund_usd
from churn_classified cc
cross join churn_total ct
group by cc.plan_change_pattern, ct.total
order by churn_events desc;


-- c) Feature usage depth: churned vs retained
-- account_engagement labels each account and calculates three engagement metrics
-- left join on subscriptions and feature_usage so accounts with no usage still appear
-- if churned accounts score lower on all three metrics, engagement is confirmed as a churn predictor
with churned_accounts as (
    select distinct account_id
    from product_analytics.churn_events
),
account_engagement as (
    select
        a.account_id,
        case when ca.account_id is not null then 'Churned' else 'Retained' end as churn_segment,
        count(distinct fu.feature_name) as distinct_features,
        sum(fu.usage_count) as total_usage_events,
        avg(fu.usage_duration_secs / 60) as avg_duration_mins
    from product_analytics.accounts a
    left join churned_accounts ca on a.account_id = ca.account_id
    left join product_analytics.subscriptions s
        on  a.account_id = s.account_id
        and s.is_trial   = 0
    left join product_analytics.feature_usage fu on s.subscription_id = fu.subscription_id
    group by a.account_id, churn_segment
)
select
    churn_segment,
    count(distinct account_id) as accounts,
    round(avg(distinct_features), 1) as avg_features_used,
    round(avg(total_usage_events), 0) as avg_usage_events,
    round(avg(avg_duration_mins), 1) as avg_session_duration_mins
from account_engagement
group by churn_segment;


-- Section 5 - Support and Churn


-- a) Ticket volume vs churn
-- ticket_segments counts tickets per account and assigns each to a volume bucket
-- hypothesis: high ticket volume signals unresolved frustration and predicts churn
with ticket_segments as (
    select
        account_id,
        count(*) as ticket_count,
        case
            when count(*) <= 2 then '1-2 tickets'
            when count(*) <= 5 then '3-5 tickets'
            else '6+ tickets'
        end as ticket_segment
    from product_analytics.support_tickets
    group by account_id
),
churned_accounts as (
    select distinct account_id
    from product_analytics.churn_events
)
select
    ticket_segment,
    count(distinct ts.account_id) as accounts,
    sum(case when ca.account_id is not null then 1 else 0 end) as churned,
    round(sum(case when ca.account_id is not null then 1 else 0 end)
        * 100.0 / count(distinct ts.account_id), 2) as churn_rate_pct
from ticket_segments ts
left join churned_accounts ca on ts.account_id = ca.account_id
group by ticket_segment
order by min(ts.ticket_count);


-- b) Satisfaction score vs churn
-- buckets accounts by average score across all their tickets
-- no score recorded kept as its own bucket, missing scores often mean unresolved issues
with satisfaction_segments as (
    select
        account_id,
        case
            when avg(satisfaction_score) is null then 'No score recorded'
            when avg(satisfaction_score) < 2.5   then 'Low (< 2.5)'
            when avg(satisfaction_score) < 4.0   then 'Medium (2.5-3.9)'
            else 'High (4.0-5.0)'
        end as sat_bucket
    from product_analytics.support_tickets
    group by account_id
),
churned_accounts as (
    select distinct account_id
    from product_analytics.churn_events
)
select
    sat_bucket,
    count(distinct ss.account_id) as accounts,
    sum(case when ca.account_id is not null then 1 else 0 end) as churned,
    round(sum(case when ca.account_id is not null then 1 else 0 end)
        * 100.0 / count(distinct ss.account_id), 2) as churn_rate_pct
from satisfaction_segments ss
left join churned_accounts ca on ss.account_id = ca.account_id
group by sat_bucket
order by churn_rate_pct desc;


-- c) High risk account identifier
-- ticket_agg summarises support history per account
-- usage_agg summarises feature engagement per account
-- coalesce converts nulls to zero so the case logic works for every account
-- risk segment logic: churned labelled first so they are never misclassified
--                     5+ tickets AND 3 or fewer features = High Risk
--                     3+ tickets OR 3 or fewer features = Medium Risk
--                     everything else = Healthy
with ticket_agg as (
    select
        account_id,
        count(*) as ticket_count,
        round(avg(satisfaction_score), 2) as avg_satisfaction,
        sum(case when escalation_flag = 1 then 1 else 0 end) as escalation_count
    from product_analytics.support_tickets
    group by account_id
),
usage_agg as (
    select
        s.account_id,
        count(distinct fu.feature_name) as distinct_features,
        sum(fu.usage_count) as total_usage_events
    from product_analytics.subscriptions s
    join product_analytics.feature_usage fu on s.subscription_id = fu.subscription_id
    where s.is_trial = 0
    group by s.account_id
),
churn_list as (
    select distinct account_id
    from product_analytics.churn_events
)
select
    a.account_id,
    a.account_name,
    a.industry,
    a.plan_tier,
    case when cl.account_id is not null then 1 else 0 end as churned,
    coalesce(t.ticket_count, 0) as ticket_count,
    t.avg_satisfaction,
    coalesce(t.escalation_count, 0) as escalation_count,
    coalesce(u.distinct_features, 0) as distinct_features,
    coalesce(u.total_usage_events, 0) as total_usage_events,
    case
        when cl.account_id is not null                         then 'Churned'
        when coalesce(t.ticket_count, 0) >= 5
             and coalesce(u.distinct_features, 0) <= 3        then 'High Risk'
        when coalesce(t.ticket_count, 0) >= 3
             or  coalesce(u.distinct_features, 0) <= 3        then 'Medium Risk'
        else 'Healthy'
    end as risk_segment
from product_analytics.accounts a
left join churn_list cl on a.account_id = cl.account_id
left join ticket_agg t  on a.account_id = t.account_id
left join usage_agg u   on a.account_id = u.account_id
order by risk_segment, coalesce(t.ticket_count, 0) desc;
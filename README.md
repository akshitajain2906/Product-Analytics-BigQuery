# Product Analytics: Trial Conversion, Retention & Churn

## Overview

Which accounts convert from trial to paid, and how quickly? Which cohorts retain, and which don't? What drives accounts to churn, and are they recoverable? This project analyses a five table SaaS dataset to answer those questions, ending with a risk segmentation model that classifies every account as Churned, High Risk, Medium Risk, or Healthy.

The analysis covers:

- 500 accounts across 5 industries
- 5,000 subscriptions spanning January 2023 to December 2024
- 25,000 feature usage logs across 40 product features
- 2,000 support tickets with satisfaction scores and escalation flags
- 600 churn events with reason codes and reactivation tracking

## Tools & Technologies

- Google BigQuery — data storage, transformation, and all analytical queries

## BigQuery

![BigQuery](Capture.PNG)

All 13 queries were executed as a single script in BigQuery, processing 4.66 MB across five tables in 5 seconds.

## Business Questions

- How long does it take trial accounts to convert to paid?
- How has MRR trended across the dataset period?
- How does retention hold up across monthly signup cohorts?
- What are the most common churn reasons, and which are most recoverable?
- Do plan changes precede churn?
- Which accounts are most at risk right now?

## Key Findings

**Trial Conversion**

All 403 trial accounts in this dataset converted to paid, a characteristic of the simulated data rather than a real world result. The more meaningful signal is conversion speed: accounts take an average of 37 days to convert, with a range of 1 to 469 days. The long tail represents accounts that needed significant time before committing.

**MRR Growth**

MRR grew from $4,684 in January 2023 to $2,273,427 in December 2024. Average MRR per account moved from $1,561 to $2,817, meaning growth came from both more accounts and higher spend per account.

**Churn Drivers**

| Reason | Churn Events | % of Churns | Avg Refund | Reactivation Rate |
|---|---|---|---|---|
| Features | 114 | 19.0% | $16.72 | 11.4% |
| Support | 104 | 17.3% | $11.73 | 5.8% |
| Budget | 104 | 17.3% | $12.00 | 11.5% |
| Unknown | 95 | 15.8% | $18.34 | 9.5% |
| Competitor | 92 | 15.3% | $13.08 | 13.0% |
| Pricing | 91 | 15.2% | $14.65 | 9.9% |

No single reason dominates churn. Support related churn has the lowest reactivation rate at 5.8% — once an account leaves over a support experience, it almost never comes back. Competitor churn has the highest at 13%, making it the strongest segment for a win back campaign.

**Plan Changes Before Churn**

72% of churned accounts left with no preceding plan change. Of the 28% that did change plan before churning, most had upgraded — only 7.5% of all churns followed a downgrade. The conventional assumption is that a downgrade signals an account on its way out. This dataset does not support that.

**Cohort Retention**

| Cohort | Size | M1 | M3 | M6 | M12 |
|---|---|---|---|---|---|
| 2023-06 | 18 | 27.8% | 33.3% | 33.3% | 50.0% |
| 2023-12 | 26 | 46.2% | 42.3% | 46.2% | 23.1% |
| 2024-03 | 25 | 60.0% | 60.0% | 60.0% | n/a |
| 2024-07 | 27 | 77.8% | 70.4% | n/a | n/a |
| 2024-11 | 37 | 86.5% | n/a | n/a | n/a |

2024 cohorts are tracking significantly higher at M1 and M3 than 2023 cohorts. M12 is only measurable for 2023 cohorts, where retention settles between 23% and 50%. Whether the improvement in recent cohorts holds at M12 is the key question this data cannot yet answer.

## Methodology

All churn analysis uses `churn_events` as the single source of truth. The `accounts` table has a `churn_flag` column marking only 110 accounts as churned, while `churn_events` captures 352 unique churned accounts. Using `churn_events` throughout avoids understating churn by more than 3x and keeps every section of the analysis consistent.

Cohorts are defined by each account's first paid subscription date, not signup date. This excludes trial periods from the active lifecycle and gives a cleaner view of paid retention. Retention is measured by whether an account had an active subscription row at each milestone, which works because the subscriptions table is a billing history table where each renewal generates a new row.

```sql
WITH cohort_base AS (
    SELECT
        account_id,
        FORMAT_DATE('%Y-%m', MIN(start_date)) AS cohort_month,
        MIN(start_date) AS first_paid_date
    FROM subscriptions
    WHERE is_trial = 0
    GROUP BY account_id
)
```

BigQuery syntax differs from MySQL throughout: `FORMAT_DATE` instead of `DATE_FORMAT`, `DATE_DIFF(date1, date2, DAY/MONTH)` instead of `DATEDIFF` and `TIMESTAMPDIFF`. Boolean flags are stored as integers, so comparisons use `= 1` and `= 0`.

## Business Implications

The data points to three clear priorities. First, support related churn is the hardest to win back — a 5.8% reactivation rate against 11 to 13% for every other reason means support experience deserves disproportionate retention investment. Second, the downgrade-before-churn assumption does not hold here; 72% of churned accounts gave no warning through a plan change, so churn prediction needs signals beyond billing behaviour. Third, the gap between 2023 and 2024 cohort retention at M1 and M3 is large enough to warrant investigating what changed in onboarding or product around early 2024, since replicating it at M12 would have a material impact on retained revenue.

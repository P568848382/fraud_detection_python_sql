--1 — Baseline: Overall Fraud Rate
-- ============================================================
-- Query 1: Baseline Fraud Statistics
-- Business Question: What does the fraud landscape look like
-- before we apply any rules?
-- ============================================================
select
    count(*)                                        as total_transactions,
    sum(is_fraud)                                   as total_fraud,
    count(*) - sum(is_fraud)                        as total_legitimate,
    round(sum(is_fraud) * 100.0 / count(*), 4)      as fraud_rate_pct,
    round(avg("Amount"), 2)                         as avg_transaction_amount,
    round(avg(case when is_fraud = 1
                   then "Amount" end), 2)           as avg_fraud_amount,
    round(avg(case when is_fraud = 0
                   then "Amount" end), 2)           as avg_legit_amount,
    round(max("Amount"), 2)                         as max_transaction_amount,
    sum(case when unusual_hour = 1 then 1 end)   as unusual_hour_transactions,
    sum(case when unusual_hour = 1
             and is_fraud = 1 then 1 end)           as fraud_in_unusual_hours
from transactions;

-- 2 — Rule 1: Flag High-Amount Transactions (Z-Score)
-- ============================================================
-- Query 2: Rule 1 — Amount Anomaly Flag (Z-Score > 3)
-- Business Question: Which transactions are statistically
-- abnormal in amount compared to the overall population?
-- Z-score > 3 means 3 standard deviations above mean.
-- ============================================================
with amount_stats as (
    select
        avg("Amount")    as mean_amt,
        stddev("Amount") as std_amt
    from transactions
),
flagged as (
    select
        t.transaction_id,
        t."Amount",
        t.is_fraud,
        t.hour_of_day,
        t.day_number,
        round(
            (t."Amount" - s.mean_amt) / nullif(s.std_amt, 0),
        4)                                           as zscore,
        case
            when (t."Amount" - s.mean_amt)
                 / nullif(s.std_amt, 0) > 3          then 'FLAGGED — High Amount'
            else 'Normal'
        end                                          as rule1_flag
    from transactions t
    cross join amount_stats s
)
select
    rule1_flag,
    count(*)                                         as transaction_count,
    sum(is_fraud)                                    as actual_fraud_caught,
    count(*) - sum(is_fraud)                         as false_positives,
    round(sum(is_fraud) * 100.0 / nullif(count(*), 0), 2)
                                                     as precision_pct,
    round(sum(is_fraud) * 100.0
          / (select sum(is_fraud) from transactions), 2)
                                                     as recall_pct
from flagged
group by rule1_flag;

-- 3 — Rule 2: Flag Unusual Hour Transactions
-- ============================================================
-- Query 3: Rule 2 — Unusual Hour Flag (Midnight to 5am)
-- Business Question: Do transactions at unusual hours (0-4am)
-- have a significantly higher fraud rate?
-- ============================================================
select
    hour_of_day,
    case
        when hour_of_day between 0 and 4 then 'Unusual Hours (0-4am)'
        when hour_of_day between 5 and 8 then 'Early Morning (5-8am)'
        when hour_of_day between 9 and 17 then 'Business Hours (9am-5pm)'
        else 'Evening (6pm-11pm)'
    end                                              as time_period,
    count(*)                                         as total_transactions,
    sum(is_fraud)                                    as fraud_count,
    round(sum(is_fraud) * 100.0 / count(*), 4)       as fraud_rate_pct,
    round(avg("Amount"), 2)                          as avg_amount,
    round(avg(case when is_fraud = 1
                   then "Amount" end), 2)            as avg_fraud_amount
from transactions
group by
    hour_of_day,
    case
        when hour_of_day between 0 and 4 then 'Unusual Hours (0-4am)'
        when hour_of_day between 5 and 8 then 'Early Morning (5-8am)'
        when hour_of_day between 9 and 17 then 'Business Hours (9am-5pm)'
        else 'Evening (6pm-11pm)'
    end
order by fraud_rate_pct desc;


-- 4 — Rule 3: High Frequency Flag Using Window Functions
-- ============================================================
-- Query 4: Rule 3 — High Frequency Transactions per Account
-- Business Question: Which accounts made more than 5 transactions
-- within any 30-minute window?
-- This is the most advanced query — uses window functions to
-- look backwards and forwards in time per account.
-- ============================================================
with account_frequency as (
    select
        transaction_id,
        account_id,
        "Time",
        "Amount",
        is_fraud,
        hour_of_day,
        -- Count transactions in the same account within ±900 seconds (15 min)
        count(*) over (
            partition by account_id
            order by "Time"
            range between 900 preceding and 900 following
        )                                           as txns_in_30min_window,
        -- Running total per account
        row_number() over (
            partition by account_id
            order by "Time"
        )                                           as account_txn_sequence,
        -- Total transactions for this account across whole dataset
        count(*) over (
            partition by account_id
        )                                           as account_total_txns,
        -- Amount rank within account — is this the largest for this account?
        rank() over (
            partition by account_id
            order by "Amount" desc
        )                                           as amount_rank_in_account
    from transactions
),
flagged as (
    select
        *,
        case
            when txns_in_30min_window > 5 then 'FLAGGED — High Frequency'
            else 'Normal'
        end                                         as rule3_flag
    from account_frequency
)
select
    rule3_flag,
    count(*)                                        as transaction_count,
    sum(is_fraud)                                   as actual_fraud_caught,
    count(*) - sum(is_fraud)                        as false_positives,
    round(sum(is_fraud) * 100.0
          / nullif(count(*), 0), 2)                as precision_pct,
    round(sum(is_fraud) * 100.0
          / (select sum(is_fraud) from transactions), 2)
                                                   as recall_pct
from flagged
group by rule3_flag;
-- Why RANGE BETWEEN 900 PRECEDING AND 900 FOLLOWING works:
-- Time is in seconds. 900 seconds = 15 minutes each side = 30-minute rolling window. 

-- 5 — Rule 4: Amount Spike Within Account
-- ============================================================
-- Query 5: Rule 4 — Amount Spike vs Account's Own Baseline
-- Business Question: Which transactions are dramatically larger
-- than the account's own typical transaction amount?
-- More precise than global z-score — compares to personal baseline.
-- ============================================================
with account_baselines as (
    select
        transaction_id,
        account_id,
        "Amount",
        is_fraud,
        hour_of_day,
        -- Each account's own average and stddev
        round(avg("Amount") over (
            partition by account_id
        ), 4)                                        as account_avg_amount,
        round(stddev("Amount") over (
            partition by account_id
        ), 4)                                        as account_std_amount,
        count(*) over (
            partition by account_id
        )                                            as account_txn_count
    from transactions
),
with_zscore as (
    select
        *,
        case
            when account_std_amount > 0
            then round(
                ("Amount" - account_avg_amount)
                / NULLIF(account_std_amount,0),
            4)
            else 0
        end                                          as account_zscore,
        round(
            "Amount" / nullif(account_avg_amount, 0),
        2)                                           as amount_vs_avg_ratio
from account_baselines
where account_txn_count >= 5
)
select
    case
        when account_zscore > 3
             or amount_vs_avg_ratio > 5
             then 'FLAGGED — Personal Amount Spike'
        else 'Normal'
    end                                              as rule4_flag,
    count(*)                                         as transaction_count,
    sum(is_fraud)                                    as actual_fraud_caught,
    count(*) - sum(is_fraud)                         as false_positives,
    round(
        sum(is_fraud) * 100.0
        / nullif(count(*), 0),
    2)                                               as precision_pct,
    round(
        sum(is_fraud) * 100.0
        / (
            select sum(is_fraud)
            from transactions
        ),
    2)                                               as recall_pct
from with_zscore
group by rule4_flag;
--Now explore above concept in more details:-
/* Detecting Fraud via Account-Level Z-Score Anomaly:-
This query calculates a rolling average and standard deviation for each account excluding the current transaction (to avoid data leakage),
then calculates a localized Z-score.
1. What is Data Leakage in this context?
In fraud analytics, data leakage happens when our system looks into the future or uses information that it wouldn't actually have
at the exact millisecond a customer swipes their card.Imagine a fraudster steals a credit card and makes a massive,
abnormal transaction of $10,000. Prior to this, the cardholder only ever made small $20 purchases.

Case A: Including the Current Row (The Wrong Way ❌)If our window function includes the current row 
(ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW), the transaction history looks like this: [$20, $20, $20, $10000].
New Mean : $2,515
New StdDev :$4,990
Now compute the Z-Score for that $10,000 transaction:
Z=(10000-2515)/4990=1.50
What Happened here:-A Z-score of 1.50 is considered completely normal! The massive $10,000 fraud amount leaked into its own baseline, 
artificially inflated the standard deviation, and hid itself from the fraud engine.
*/
--To avoid from this we choose  case B
/*
Case B: Excluding the Current Row (The Correct Way  ✅)By using ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING,
we calculate the baseline using only what happened before this moment: [$20, $20, $20].
Historical Mean : $20 
Historical StdDev :$0 (or near zero)Now compute the Z-Score for that $10,000 transaction against its true historical baseline:
Z = (10000 - 20)/0.00001 = 998,000.00
An astronomical Z-score! The transaction immediately sets off alarm bells, and the bank blocks the card.
*/
with account_historical_stats as (
    select 
        transaction_id,
        account_id,
        day_number,
        hour_of_day,
        "Amount",
        is_fraud,
        -- Calculate average of past transactions for this account specifically
        avg("Amount") over(
            partition by account_id 
            order by transaction_id
            rows between unbounded preceding and 1 preceding
        ) as local_mean,
        -- Calculate standard deviation of past transactions for this account
        stddev("Amount") over(
            partition by account_id 
            order by transaction_id
            rows between unbounded preceding and 1 preceding
        ) as local_stddev
    from transactions
),
local_z_score_calc as (
    select 
        transaction_id,
        account_id,
        day_number,
        hour_of_day,
        "Amount",
        is_fraud,
        local_mean,
        local_stddev,
        -- Compute local Z-Score. Use CASE to prevent Division by Zero on brand new accounts
        case 
            when local_stddev is null or local_stddev = 0 then 0
            else ("Amount" - local_mean) / NULLIF(local_stddev,0)
        end as local_z_score
    from account_historical_stats
)
-- Flag anomalies where the transaction exceeds 3 standard deviations of their personal norm
select 
    transaction_id,
    account_id,
    "Amount",
    round(local_mean, 2) as user_avg_spending,
    round(local_z_score, 2) as deviation_score,
    is_fraud
from local_z_score_calc
where local_z_score > 3 and is_fraud=1
order by local_z_score desc;
/*
When designing the localized Z-score feature in SQL, I intentionally set the window frame to end at 1 PRECEDING rather than CURRENT ROW.
Including the current transaction in its own statistical baseline introduces severe data leakage and mathematical smoothing. 
If a fraudster attempts a massive high-value anomaly, that large value will skew the mean and drastically inflate the standard deviation 
instantly. This flattens the resulting Z-score, causing the anomaly to camouflage itself within its own inflated boundaries.
By lagging the window boundary by one row, the engine evaluates the current transaction strictly against a pristine,
historical baseline of the user's past behavior, preserving the statistical signal required to catch sudden spikes.
*/
-- 6: Fraud Velocity Rules (Card-Testing Frequency)
-- Fraudsters often test if a card works by running multiple transactions in rapid succession. 
-- Since you engineered day_number and hour_of_day, we can measure "velocity spikes" (high count of transactions per hour).
with hourly_velocity as(
    select 
        transaction_id,
        account_id,
        day_number,
        hour_of_day,
        is_fraud,
        -- Count how many times this account transacted within the exact same hour block
        count(*) over(
            partition by account_id, day_number, hour_of_day
        ) as tx_per_hour

    from transactions
)
-- Aggregate to find if higher transaction velocity directly correlates to higher fraud rates
select 
    tx_per_hour as transactions_in_single_hour,
    count(*) as total_instances,
    sum(is_fraud) as fraud_cases,
    round((sum(is_fraud)::numeric / count(*)) * 100, 4) as fraud_rate_percentage
from hourly_velocity
group by tx_per_hour
order by fraud_rate_percentage desc;

-- 7 — Combined Rule Engine: Fraud Score 0–100
-- ============================================================
-- Query 7: Fraud Scoring Engine — Combine All Rules
-- Business Question: Instead of a binary flag, assign each
-- transaction a risk score based on how many rules it triggers.
-- This is the STRETCH GOAL from the project spec.
-- ============================================================
with amount_stats as(
select avg("Amount") as mean_amt,
	   stddev("Amount") as std_amt
from transactions
),
account_stats as(
select account_id,
	   avg("Amount") as acct_avg,
	   stddev("Amount") as acct_std,
	   count(*) as acct_txn_count
from transactions
group by account_id
),
frequency_window as(
select transaction_id,
	   count(*)over(
					partition by account_id
					order by "Time"
					range between 900 preceding and 900 following
	   				) as txns_in_30min
from transactions
),
scored as(
select t.transaction_id,
	   t."Amount",
	   t.is_fraud,
	   t.hour_of_day,
	   t.day_number,
	   t.account_id,
	   t.unusual_hour,
	   fw.txns_in_30min,
	   -- ── Rule scores (sum = raw fraud score) ────────────
       -- Rule 1: Global amount anomaly (weight: 40)
	   case when (t."Amount" - s.mean_amt)/nullif(s.std_amt,0) > 3 then 40
	   		when (t."Amount" - s.mean_amt)/nullif(s.std_amt,0) > 2 then 20
			else 0
	   end as rule1_score,
	   -- Rule 2: Unusual transaction hour (weight: 20)
	   case when t.unusual_hour = 1 then 20
	   		else 0
		end as rule2_score,
		-- Rule 3: High frequency in 30-minute window (weight: 25)
		case when fw.txns_in_30min > 5 then 25
		     when fw.txns_in_30min > 3 then 10
			 else 0
		end as rule3_score,
		-- Rule 4: Spike vs personal account average (weight: 15)
		case when a.acct_txn_count >= 5 
				  and a.acct_std > 0
				  and (t."Amount" - a.acct_avg)/nullif(a.acct_std,0) > 3 then 15
			 when a.acct_txn_count >= 5
			 	  and a.acct_avg > 0
				   and t."Amount"/a.acct_avg > 5 then 15
			else 0
		end as rule4_score
from transactions t
cross join amount_stats s
join account_stats a on t.account_id = a.account_id
join frequency_window fw on t.transaction_id=fw.transaction_id
),
final_scored as(
select *,
	   (rule1_score + rule2_score + rule3_score +rule4_score) as total_fraud_score,
	   case when (rule1_score + rule2_score + rule3_score +rule4_score) >= 50 then 'High Risk'
	        when (rule1_score + rule2_score + rule3_score +rule4_score) >=25 then 'Medium Risk'
			when (rule1_score + rule2_score + rule3_score +rule4_score) >= 0 then 'Low Risk'
			else 'Clean'
		end as risk_label
from scored
)
select risk_label,
	   count(*) as transaction_count,
	   sum(is_fraud) as actual_fraud_caught,
	   count(*) - sum(is_fraud) as false_positives,
	   round(sum(is_fraud)*100.0
	   		 /nullif(count(*),0),2
				)'%' as precision_pct,
	   round(sum(is_fraud)*100.0
	   		 /(select sum(is_fraud) from transactions),2
				)'%' as recall_pct,
		round(avg("Amount"),2) as avg_amount_in_group,
		round(avg(total_fraud_score),2) as avg_score_in_group
from final_scored
group by risk_label
order by case risk_label
			 when 'High Risk' then 1
			 when 'Medium Risk' then 2
			 when 'Low Risk' then 3
			 else 4
		end;

-- 8 — Rule Effectiveness Comparison
-- ============================================================
-- Query 8: Which Rule Catches the Most Fraud?
-- Compare precision and recall across all 4 rules in one query.
-- This is what a fraud team actually needs to decide which rules
-- to deploy, which to tune, and which to drop.
-- ============================================================
with amount_stats as(
select avg("Amount") as mean_amt,
	   stddev("Amount") as std_amount
from transactions
),
rule_flags as(
select t.transaction_id,
       t.is_fraud,
	   t."Amount",
	   --Rule 1
	   case when (t."Amount" - s.mean_amt)/nullif(s.std_amount,0)>3 then 1 else 0 end as r1,
	   --Rule 2
	   t.unusual_hour as r2,
	   --Rule 3(Simplified - accounts with > 10 total transactions as proxy)
	   case when count(*)over(partition by t.account_id) > 10
	        then 1 else 0 end as r3_proxy,
	   --Rule 4(large amount relative to account_avg)
	   case when t."Amount" > 2 * avg(t."Amount")over(partition by t.account_id) 
	        then 1 else 0 end as r4
from transactions t
cross join amount_stats s
)
select rule_name,
		flagged_count,
		fraud_count,	
		false_positives,
		round(fraud_count*100.0/nullif(flagged_count,0),2)||'%' as precision_pct,
		round(fraud_count*100.0/(select sum(is_fraud) from transactions),2)||'%' as recall_pct,
		round(
			2.0 * (fraud_count*100.0/nullif(flagged_count,0))
			* (fraud_count*100.0/(select sum(is_fraud) from transactions))
			/nullif(
					(fraud_count*100.0/nullif(flagged_count,0))
					+(fraud_count*100.0)/(select sum(is_fraud) from transactions)
			,0),
			2) as f1_score
		
from(
select 'Rule 1 - High Amount(Z > 3)' as rule_name,
		sum(r1) as flagged_count,
		sum(r1*is_fraud) as fraud_count,
		sum(r1) - sum(r1*is_fraud) as false_positives
from rule_flags
union all
select 'Rule 2 - Unusual Hour(0-4AM)',
	    sum(r2),
		sum(r2*is_fraud),
		sum(r2) - sum(r2*is_fraud)
from rule_flags
union all
select 'Rule 3 - High Freq Account(proxy)',
       sum(r3_proxy),
	   sum(r3_proxy*is_fraud),
	   sum(r3_proxy) - sum(r3_proxy*is_fraud)
from rule_flags
union all
select 'Rule 4 - Amount Spike vs Acct_avg',
	   sum(r4),
	   sum(r4*is_fraud),
	   sum(r4) - sum(r4*is_fraud)
from rule_flags
)rule_summary
order by f1_score desc;


-- 8 — Top 50 Highest Risk Transactions (Final Output)
-- ============================================================
-- Query 8: Final Flagged Transactions List — Ranked by Risk Score
-- This is the output a fraud analyst team would actually review.
-- Highest scoring transactions surfaced first.
-- ============================================================
with amount_stats as(
select avg("Amount") as mean_amt,
	   stddev("Amount") as std_amt
from transactions
),
account_stats as(
select account_id,
	   avg("Amount") as acct_avg,
	   stddev("Amount") as acct_std,
	   count(*) as acct_txns_count
from transactions
group by account_id
),
frequency_window as(
select transaction_id,
       count(*)over(partition by account_id order by "Time" range between 900 preceding and 900 following) as txns_in_30min
from transactions
),
scored as(
select t.transaction_id,
	   t."Time",
	   t.hour_of_day,
	   t.day_number,
	   t.account_id,
	   round(t."Amount",2) as amount,
	   t.is_fraud as actual_label,
	   fw.txns_in_30min,
	   case when (t."Amount" - s.mean_amt)/nullif(s.std_amt,0) > 3 then 40
	   		when (t."Amount" - s.mean_amt)/nullif(s.std_amt,0) > 2 then 20
		else 0 end as score_r1,
		case when t.unusual_hour = 1 then 20
		     else 0 end as score_r2,
		case when fw.txns_in_30min > 5 then 25
		     when fw.txns_in_30min > 3 then 10
		else 0 end as score_r3,
		case when a.acct_txns_count >= 5
			and a.acct_std > 0
			and (t."Amount" - a.acct_avg)/a.acct_std >3 then 15
			else 0 end as score_r4
from transactions t
cross join amount_stats s
join account_stats a on t.account_id=a.account_id
join frequency_window fw on t.transaction_id=fw.transaction_id	   
)
select transaction_id,
	   day_number,
	   hour_of_day,
	   account_id,
	   amount,
	   txns_in_30min,
	   score_r1 + score_r2 + score_r3 +score_r4 as total_fraud_score,
	   case when score_r1 + score_r2 + score_r3 +score_r4 > 50 then 'High Risk'
	   	    when score_r1 + score_r2 + score_r3 +score_r4 > 25 then 'Medium Risk'
	        else 'Low Risk'
		end  as risk_label,
		score_r1 as rule1_amount_flag,
		score_r2 as rule2_hour_flag,
		score_r3 as rule3_freq_flag,
		score_r4 as rule4_spike_flag,
		actual_label as is_actual_fraud,
		rank()over(order by score_r1 + score_r2 + score_r3 +score_r4 desc, amount desc) as overall_risk_rank
from scored
where score_r1 + score_r2 + score_r3 +score_r4 > 0
order by overall_risk_rank
limit 50;

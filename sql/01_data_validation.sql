select * from transactions limit 15;

--Shape
select count(*) as total_transactions from transactions;
--o/p:-2,84,807

-- Fraud class distribution
select is_fraud,
		count(*) as headcount,
		round(count(*)*100.0
		/sum(count(*))over(),4)||'%' as pct
from transactions
group by is_fraud;
-- o/p:-
/*
"is_fraud"	"headcount"	"pct"
0	284315	"99.8273%"
1	492	"0.1727%"
*/
--Amount Statistics
select round(min("Amount"),2) as min_amount,
	   round(max("Amount"),2) as max_amount,
	   round(avg("Amount"),2) as avg_amount,
	   round(stddev("Amount"),2) as std_amount,
	   round(avg("Amount") + 3*stddev("Amount"),2) as three_sigma_thresold,
	   percentile_cont(0.5) within group (order by "Amount") as median_amount,
	   percentile_cont(0.95) within group (order by "Amount") as p95_amount,
	   percentile_cont(0.99) within group (order by "Amount") as p99_amount
from transactions;
--o/p:-
/*
"min_amount"	"max_amount"	"avg_amount"	"std_amount"	"three_sigma_thresold"	"median_amount"	"p95_amount"	"p99_amount"
	0.00		   25691.16			88.35			250.12				838.71					22			365			   1017.90
*/

--Fraud by hour of day
select hour_of_day,
	   count(*) as total_transactions,
	   sum(is_fraud) as fraud_count,
	   round(sum(is_fraud)*100.0/count(*),4)||'%' as fraud_rate_pct
from transactions
group by hour_of_day
order by hour_of_day;
--o/p:-
"hour_of_day"	"total_transactions"	"fraud_count"	"fraud_rate_pct"
0	7695	6	"0.0780%"
1	4220	10	"0.2370%"
2	3328	57	"1.7127%"
3	3492	17	"0.4868%"
4	2209	23	"1.0412%"
5	2990	11	"0.3679%"
6	4101	9	"0.2195%"
7	7243	23	"0.3175%"
8	10276	9	"0.0876%"
9	15838	16	"0.1010%"
10	16598	8	"0.0482%"
11	16856	53	"0.3144%"
12	15420	17	"0.1102%"
13	15365	17	"0.1106%"
14	16570	23	"0.1388%"
15	16461	26	"0.1579%"
16	16453	22	"0.1337%"
17	16166	29	"0.1794%"
18	17039	33	"0.1937%"
19	15649	19	"0.1214%"
20	16756	18	"0.1074%"
21	17703	16	"0.0904%"
22	15441	9	"0.0583%"
23	10938	21	"0.1920%"
--Day distribution
select day_number,
	   count(*) as transactions,
	   sum(is_fraud) as fraud_transactions
from transactions
group by day_number
order by day_number;
-- o/p:-
"day_number"	"transactions"	"fraud_transactions"
	1			   144786	           281
	2	           140021			   211

--Amount Z-score check
select count(case when abs(amount_zscore) > 3 then 1 end) as flagged_by_zscore,
       sum(case when abs(amount_zscore) > 3  and is_fraud=1 then 1 else 0 end) AS actual_fraud_in_flagged,
	   count(case when is_fraud=1 then 1 end) as total_fraud
from transactions;
-- o/p:-
/*
"flagged_by_zscore"	"actual_fraud_in_flagged"	"total_fraud"
4076	11	492
*/
       
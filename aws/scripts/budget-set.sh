#!/bin/bash
# Set this tenant's monthly spending limit — sized from what it ACTUALLY costs,
# not a number someone typed once. Idempotent; safe to re-run monthly.
#
# DORMANT BY DEFAULT, like backups and build boxes: no /asp/budget/config
# parameter means no budget and no failure.
#
# Sizing, in order of preference:
#   1. the tenant's own billed history (3-month max, the honest worst case)
#   2. for a tenant too new to have history, a model from the measured rate card
#      below × the terminals that actually exist × expected hours
# then + headroom, so a normal month does not page anybody.
#
# Thresholds ALERT. They do not stop anything: killing a terminal mid-session to
# save a few dollars is worse than the overspend. Enforcement, if a tenant wants
# it, belongs on ec2:RunInstances (no NEW terminals) and not on running ones —
# see runbooks/budgets.md.
set -uo pipefail
# shellcheck source=/dev/null
source /etc/asp-terminal.env 2>/dev/null || true
REGION="${ASP_REGION:-us-east-2}"

CONF=$(aws ssm get-parameter --name /asp/budget/config --region "$REGION" \
        --query Parameter.Value --output text 2>/dev/null) || CONF=""
if [ -z "$CONF" ] || [ "$CONF" = "None" ]; then
  echo "budget-set: no /asp/budget/config in this tenant — no budget set (by design)"
  exit 0
fi
conf() { echo "$CONF" | python3 -c "import json,sys;print(json.load(sys.stdin).get('$1',''))"; }
EMAIL=$(conf ALERT_EMAIL)
HOURS=$(conf HOURS_PER_TERMINAL); HOURS=${HOURS:-25}
HEADROOM=$(conf HEADROOM_PCT);    HEADROOM=${HEADROOM:-30}
[ -n "$EMAIL" ] || { echo "budget-set: config present but ALERT_EMAIL missing — not setting a budget" >&2; exit 1; }

ACCT=$(aws sts get-caller-identity --query Account --output text)
# how many terminals this tenant actually has, however they were created
TERMINALS=$(aws ec2 describe-instances --region "$REGION" \
  --filters Name=tag:Role,Values=desktop Name=instance-state-name,Values=running,stopped,stopping,pending \
  --query 'length(Reservations[].Instances[])' --output text 2>/dev/null || echo 0)

# ---- 1. what has this tenant actually cost? (Cost Explorer is us-east-1 only)
# SCOPED TO THE PLATFORM'S REGION. An account-wide figure is the wrong number:
# on an operator account it picks up domains, unrelated instances and old
# experiments, and a budget sized to those is not a limit — the first run of
# this script asked for $591 because a five-month-old $454 month was in range.
# Complete months only; the current partial month would understate.
HIST=$(aws ce get-cost-and-usage --region us-east-1 \
  --time-period Start="$(date -u -d '3 months ago' +%Y-%m-01)",End="$(date -u +%Y-%m-01)" \
  --granularity MONTHLY --metrics UnblendedCost \
  --filter "{\"Dimensions\":{\"Key\":\"REGION\",\"Values\":[\"$REGION\"]}}" \
  --query 'ResultsByTime[].Total.UnblendedCost.Amount' --output text 2>/dev/null || echo "")
PEAK=$(echo "$HIST" | tr '\t' '\n' | sort -gr | head -1)
PEAK=${PEAK:-0}

# ---- 2. model, for a tenant with no full month yet -------------------------
# Rate card MEASURED on the pilot tenant, us-east-2, 2026-08. Other regions
# differ; a tenant with history never uses these numbers.
MODEL=$(python3 - "$TERMINALS" "$HOURS" <<'PY'
import sys
n, hours = int(sys.argv[1]), float(sys.argv[2])
fixed = 12.26 + 1.60 + 3.07 + 0.32 + 7.30      # control plane + NAT + 2 EIP
per   = 50*0.08 + 125*0.040 + hours*0.0860     # 50GB gp3 + 250MB/s + compute
gb    = n * hours * 1.74                        # measured DCV stream per hour
egress = max(0.0, gb - 100) * 0.09 + gb * 0.01  # internet out + cross-AZ
print(f"{fixed + n*per + egress:.2f}")
PY
)

BASE=$(python3 -c "print(max($PEAK, $MODEL))")
AMOUNT=$(python3 -c "print(round($BASE * (1 + $HEADROOM/100), 2))")
echo "budget-set: terminals=$TERMINALS  peak-month=\$$PEAK  model=\$$MODEL  ->  limit=\$$AMOUNT (+${HEADROOM}%)"

# ---- 3. create or update -------------------------------------------------
BUDGET=asp-terminals-monthly
# The budget must be SCOPED the same way it was sized. An unscoped COST budget
# measures the whole account, so on an operator account it reads domains and
# unrelated instances as terminal spend — this budget showed 96% consumed the
# moment it was created, before the platform had spent $31.
PAYLOAD=$(python3 - "$BUDGET" "$AMOUNT" "$REGION" <<'PJ'
import json,sys
print(json.dumps({"BudgetName":sys.argv[1],"BudgetLimit":{"Amount":sys.argv[2],"Unit":"USD"},
                  "TimeUnit":"MONTHLY","BudgetType":"COST",
                  "CostFilters":{"Region":[sys.argv[3]]}}))
PJ
)
NOTIFS=$(python3 - "$EMAIL" <<'PY'
import json,sys
out=[]
for pct in (80,100,120):
    out.append({"Notification":{"NotificationType":"ACTUAL" if pct<120 else "FORECASTED",
                "ComparisonOperator":"GREATER_THAN","ThresholdType":"PERCENTAGE","Threshold":pct},
                "Subscribers":[{"SubscriptionType":"EMAIL","Address":sys.argv[1]}]})
print(json.dumps(out))
PY
)
if aws budgets describe-budget --account-id "$ACCT" --budget-name "$BUDGET" >/dev/null 2>&1; then
  aws budgets update-budget --account-id "$ACCT" --new-budget "$PAYLOAD" \
    && echo "budget-set: updated $BUDGET to \$$AMOUNT/month"
else
  aws budgets create-budget --account-id "$ACCT" --budget "$PAYLOAD" \
    --notifications-with-subscribers "$NOTIFS" \
    && echo "budget-set: created $BUDGET at \$$AMOUNT/month, alerting $EMAIL at 80/100/120%"
fi
